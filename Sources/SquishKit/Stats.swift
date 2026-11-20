import Foundation

// MARK: Model

/// What kind of file a stat is about. Used for colors and the "by kind" breakdown.
public enum StatKind: String, Codable, CaseIterable, Sendable {
    case image, video, audio, pdf, svg

    public init(fileExtension ext: String) {
        switch ext.lowercased() {
        case "mp4", "mov", "m4v": self = .video
        case "m4a", "mp3", "aac": self = .audio
        case "pdf": self = .pdf
        case "svg": self = .svg
        default: self = .image
        }
    }
}

/// Where a file came from.
public enum StatSource: String, Codable, CaseIterable, Sendable {
    case clipboard, folder, manual, shortcut
}

/// One finished optimization. Kept small: thousands of these sync through iCloud Drive or OneDrive.
public struct StatEvent: Codable, Hashable, Sendable {
    public var date: Date
    public var kind: StatKind
    /// File extension, lowercased ("png", "jpg"). For SVG conversions, "svg".
    public var format: String
    public var source: StatSource
    public var originalSize: Int
    public var newSize: Int
    public var milliseconds: Int
    /// File name only, never a path.
    public var name: String

    public init(date: Date, kind: StatKind, format: String, source: StatSource, originalSize: Int, newSize: Int,
                milliseconds: Int, name: String) {
        self.date = date
        self.kind = kind
        self.format = format
        self.source = source
        self.originalSize = originalSize
        self.newSize = newSize
        self.milliseconds = milliseconds
        self.name = name
    }

    public var saved: Int { max(0, originalSize - newSize) }

    /// Same job: same moment, file and original size. Used to undo a stat when the original is restored.
    public func sameFile(as other: StatEvent) -> Bool {
        abs(date.timeIntervalSince(other.date)) < 0.001 && name == other.name && originalSize == other.originalSize
    }
    public var improved: Bool { newSize < originalSize }
    /// 0...1, how much smaller the file got.
    public var reduction: Double { originalSize > 0 ? Double(saved) / Double(originalSize) : 0 }

    enum CodingKeys: String, CodingKey {
        case date = "d", kind = "k", format = "x", source = "s", originalSize = "o", newSize = "n", milliseconds = "t", name = "f"
    }

    // Unknown kinds or sources from newer versions decode as defaults instead of failing the file.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        kind = (try? c.decode(StatKind.self, forKey: .kind)) ?? .image
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        source = (try? c.decode(StatSource.self, forKey: .source)) ?? .manual
        originalSize = try c.decode(Int.self, forKey: .originalSize)
        newSize = try c.decode(Int.self, forKey: .newSize)
        milliseconds = try c.decodeIfPresent(Int.self, forKey: .milliseconds) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

/// Totals for events dropped from the log to keep the file small. Count toward lifetime numbers only.
public struct StatTotals: Codable, Equatable, Sendable {
    public var saved = 0
    public var originalSize = 0
    public var files = 0

    public init() {}

    mutating func add(_ event: StatEvent) {
        guard event.improved else { return }
        saved += event.saved
        originalSize += event.originalSize
        files += 1
    }
}

/// One Mac's stats. Each Mac writes only its own file, so syncing never overwrites another Mac's numbers.
public struct StatsFile: Codable, Equatable, Sendable {
    public var format = 1
    public var deviceID: String
    public var deviceName: String
    public var events: [StatEvent] = []
    public var archived = StatTotals()

    /// Past this, the oldest events fold into `archived`.
    public static let maxEvents = 25_000

    public init(deviceID: String, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    public mutating func append(_ new: [StatEvent]) {
        events.append(contentsOf: new)
        compact()
    }

    /// Drops one matching event per entry in `events`.
    public mutating func remove(_ events: [StatEvent]) {
        for event in events {
            if let index = self.events.lastIndex(where: { $0.sameFile(as: event) }) { self.events.remove(at: index) }
        }
    }

    /// Adds events from another copy of this Mac's file (the local one, when sync is turned on), skipping duplicates.
    public mutating func merge(_ other: StatsFile) {
        let known = Set(events)
        events.append(contentsOf: other.events.filter { !known.contains($0) })
        events.sort { $0.date < $1.date }
        archived.saved += other.archived.saved
        archived.originalSize += other.archived.originalSize
        archived.files += other.archived.files
        compact()
    }

    mutating func compact() {
        guard events.count > Self.maxEvents else { return }
        let overflow = events.count - Self.maxEvents
        events[..<overflow].forEach { archived.add($0) }
        events.removeFirst(overflow)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        deviceID = try c.decode(String.self, forKey: .deviceID)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? "Mac"
        events = try c.decodeIfPresent([StatEvent].self, forKey: .events) ?? []
        archived = try c.decodeIfPresent(StatTotals.self, forKey: .archived) ?? StatTotals()
    }
}

// MARK: Reading and writing

public enum StatsIO {
    /// Every `*.json` stats file in `folder`. Blocks while a cloud provider downloads; call off the main actor.
    public static func readAll(in folder: URL) -> [StatsFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap(read)
    }

    public static func read(_ url: URL) -> StatsFile? {
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
            data = try? Data(contentsOf: url)
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(StatsFile.self, from: data)
    }

    public static func write(_ file: StatsFile, to url: URL) throws {
        let data = try JSONEncoder().encode(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var result: Result<Void, any Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            result = Result { try data.write(to: url, options: .atomic) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }
}

// MARK: Reports

public enum StatPeriod: String, CaseIterable, Sendable {
    case day, week, month, year, all
}

public struct KindTotal: Equatable, Sendable {
    public var saved = 0
    public var files = 0

    public init() {}
}

/// One bar in the activity chart.
public struct StatBucket: Equatable, Sendable {
    public var start: Date
    public var saved: Int
    public var files: Int
}

public struct DeviceTotal: Equatable, Sendable {
    public var name: String
    public var saved: Int
    public var files: Int
}

/// Numbers for one period (today, this week, ...), across every Mac.
public struct PeriodReport: Sendable {
    public var period: StatPeriod
    public var saved = 0
    public var originalSize = 0
    /// Files that got smaller.
    public var files = 0
    /// Files Squish checked that were already as small as they get.
    public var alreadyOptimal = 0
    public var milliseconds = 0
    public var byKind: [StatKind: KindTotal] = [:]
    public var bySource: [StatSource: KindTotal] = [:]
    /// Extensions by bytes saved, largest first.
    public var byFormat: [(format: String, total: KindTotal)] = []
    public var byDevice: [DeviceTotal] = []
    /// Largest file handled.
    public var heaviest: StatEvent?
    /// Highest percentage saved, among files of at least 10 KB.
    public var bestRatio: StatEvent?
    /// Most bytes saved on a single file.
    public var biggestWin: StatEvent?
    public var buckets: [StatBucket] = []
    /// .hour, .day or .month: what one bucket spans.
    public var bucketUnit: Calendar.Component = .day

    /// Average reduction across the files that got smaller, 0...1.
    public var averageReduction: Double { originalSize > 0 ? Double(saved) / Double(originalSize) : 0 }
}

/// Numbers that don't depend on the chosen period.
public struct LifetimeReport: Sendable {
    public var saved = 0
    public var files = 0
    public var currentStreak = 0
    public var longestStreak = 0
    public var bestDay: (date: Date, saved: Int)?
    /// 0...23, the hour with the most files.
    public var favoriteHour: Int?
    public var firstDate: Date?
    /// Bytes saved per day, keyed by the start of the day.
    public var daily: [Date: Int] = [:]
}

public struct StatsReport: Sendable {
    public let files: [StatsFile]
    public let now: Date
    public let calendar: Calendar

    public init(files: [StatsFile], now: Date = .now, calendar: Calendar = .current) {
        self.files = files
        self.now = now
        self.calendar = calendar
    }

    public var isEmpty: Bool { files.allSatisfy { $0.events.isEmpty && $0.archived.files == 0 } }

    /// When `period` started, or nil for all time.
    public func start(of period: StatPeriod) -> Date? {
        switch period {
        case .day: calendar.startOfDay(for: now)
        case .week: calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month: calendar.dateInterval(of: .month, for: now)?.start
        case .year: calendar.dateInterval(of: .year, for: now)?.start
        case .all: nil
        }
    }

    public func report(for period: StatPeriod) -> PeriodReport {
        let start = start(of: period)
        var report = PeriodReport(period: period)
        var formats: [String: KindTotal] = [:]
        var devices: [DeviceTotal] = []

        for file in files {
            var device = DeviceTotal(name: file.deviceName, saved: 0, files: 0)
            for event in file.events where start.map({ event.date >= $0 }) ?? true && event.date <= now {
                report.milliseconds += event.milliseconds
                guard event.improved else {
                    report.alreadyOptimal += 1
                    continue
                }
                report.saved += event.saved
                report.originalSize += event.originalSize
                report.files += 1
                report.byKind[event.kind, default: KindTotal()].add(event)
                report.bySource[event.source, default: KindTotal()].add(event)
                formats[event.format.isEmpty ? "other" : event.format, default: KindTotal()].add(event)
                device.saved += event.saved
                device.files += 1
                if event.originalSize > report.heaviest?.originalSize ?? -1 { report.heaviest = event }
                if event.saved > report.biggestWin?.saved ?? -1 { report.biggestWin = event }
                if event.originalSize >= 10_240, event.reduction > report.bestRatio?.reduction ?? -1 { report.bestRatio = event }
            }
            if period == .all {
                report.saved += file.archived.saved
                report.originalSize += file.archived.originalSize
                report.files += file.archived.files
                device.saved += file.archived.saved
                device.files += file.archived.files
            }
            if device.files > 0 {
                if let index = devices.firstIndex(where: { $0.name == device.name }) {
                    devices[index].saved += device.saved
                    devices[index].files += device.files
                } else {
                    devices.append(device)
                }
            }
        }
        report.byFormat = formats.sorted { $0.value.saved > $1.value.saved }.map { ($0.key, $0.value) }
        report.byDevice = devices.sorted { $0.saved > $1.saved }
        (report.buckets, report.bucketUnit) = buckets(for: period, from: start)
        return report
    }

    /// Hours for today, days for the week and month, months for the year and all time (at most the last 24).
    private func buckets(for period: StatPeriod, from start: Date?) -> ([StatBucket], Calendar.Component) {
        let unit: Calendar.Component
        var first: Date
        switch period {
        case .day: unit = .hour; first = start ?? now
        case .week, .month: unit = .day; first = start ?? now
        case .year: unit = .month; first = start ?? now
        case .all:
            unit = .month
            let earliest = allEvents.map(\.date).min() ?? now
            let floor = calendar.date(byAdding: .month, value: -23, to: now) ?? earliest
            first = max(earliest, floor)
        }
        first = calendar.dateInterval(of: unit, for: first)?.start ?? first
        let end: Date = switch period {
        case .day: calendar.date(byAdding: .day, value: 1, to: first)!
        case .week: calendar.date(byAdding: .weekOfYear, value: 1, to: first)!
        case .month: calendar.date(byAdding: .month, value: 1, to: first)!
        case .year: calendar.date(byAdding: .year, value: 1, to: first)!
        case .all: calendar.date(byAdding: .month, value: 1, to: calendar.dateInterval(of: .month, for: now)!.start)!
        }
        var buckets: [StatBucket] = []
        var cursor = first
        while cursor < end {
            buckets.append(StatBucket(start: cursor, saved: 0, files: 0))
            cursor = calendar.date(byAdding: unit, value: 1, to: cursor)!
        }
        for event in allEvents where event.improved && event.date >= first && event.date < end {
            guard let bucketStart = calendar.dateInterval(of: unit, for: event.date)?.start,
                  let index = buckets.firstIndex(where: { $0.start == bucketStart }) else { continue }
            buckets[index].saved += event.saved
            buckets[index].files += 1
        }
        return (buckets, unit)
    }

    private var allEvents: [StatEvent] { files.flatMap(\.events) }

    public func lifetime() -> LifetimeReport {
        var report = LifetimeReport()
        var hours = [Int](repeating: 0, count: 24)
        for file in files {
            report.saved += file.archived.saved
            report.files += file.archived.files
        }
        for event in allEvents where event.improved {
            report.saved += event.saved
            report.files += 1
            report.daily[calendar.startOfDay(for: event.date), default: 0] += event.saved
            hours[calendar.component(.hour, from: event.date)] += 1
            if event.date < report.firstDate ?? .distantFuture { report.firstDate = event.date }
        }
        if let best = report.daily.max(by: { $0.value < $1.value }) { report.bestDay = (best.key, best.value) }
        if let busiest = hours.indices.max(by: { hours[$0] < hours[$1] }), hours[busiest] > 0 { report.favoriteHour = busiest }
        (report.currentStreak, report.longestStreak) = streaks(days: Set(report.daily.keys))
        return report
    }

    /// Consecutive days with at least one file squished. Today still counts as "in progress":
    /// a streak that ended yesterday is current until today is over.
    func streaks(days: Set<Date>) -> (current: Int, longest: Int) {
        let sorted = days.sorted()
        var longest = 0
        var run = 0
        var previous: Date?
        for day in sorted {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day { run += 1 } else { run = 1 }
            longest = max(longest, run)
            previous = day
        }
        let today = calendar.startOfDay(for: now)
        var cursor = days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        var current = 0
        while days.contains(cursor) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return (current, longest)
    }
}

extension KindTotal {
    mutating func add(_ event: StatEvent) {
        saved += event.saved
        files += 1
    }
}
