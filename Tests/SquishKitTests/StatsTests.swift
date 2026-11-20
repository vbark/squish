import Foundation
import Testing
@testable import SquishKit

struct StatsTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2 // Monday
        return calendar
    }()

    /// Saturday 14 November 2026, 15:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_794_668_400)

    static func event(_ daysAgo: Double, _ original: Int, _ new: Int, kind: StatKind = .image, format: String = "png",
                      source: StatSource = .clipboard, name: String = "file.png", hour: Double = 0) -> StatEvent {
        StatEvent(date: now.addingTimeInterval(-daysAgo * 86_400 + hour * 3600), kind: kind, format: format, source: source,
                  originalSize: original, newSize: new, milliseconds: 100, name: name)
    }

    static func file(_ events: [StatEvent], device: String = "MacBook") -> StatsFile {
        var file = StatsFile(deviceID: device, deviceName: device)
        file.append(events)
        return file
    }

    @Test func `periods include only their own events`() {
        let file = Self.file([
            Self.event(0, 1000, 400),       // today
            Self.event(3, 2000, 1000),      // this week (Wednesday)
            Self.event(10, 5000, 1000),     // this month
            Self.event(100, 9000, 1000),    // this year
            Self.event(400, 10_000, 1000),  // last year
        ])
        let report = StatsReport(files: [file], now: Self.now, calendar: Self.calendar)
        #expect(report.report(for: .day).saved == 600)
        #expect(report.report(for: .week).saved == 1600)
        #expect(report.report(for: .month).saved == 5600)
        #expect(report.report(for: .year).saved == 13_600)
        #expect(report.report(for: .all).saved == 22_600)
    }

    @Test func `records pick the heaviest, best ratio and biggest win`() {
        let file = Self.file([
            Self.event(0, 50_000_000, 45_000_000, kind: .video, format: "mp4", name: "movie.mp4"),  // heaviest, biggest win
            Self.event(0, 200_000, 20_000, name: "icon.png"),                                        // best ratio (90%)
            Self.event(0, 5_000, 100, name: "tiny.png"),                                             // 98% but under 10 KB
            Self.event(0, 1_000_000, 1_000_000, name: "already.jpg"),                                // already optimal
        ])
        let report = StatsReport(files: [file], now: Self.now, calendar: Self.calendar).report(for: .day)
        #expect(report.heaviest?.name == "movie.mp4")
        #expect(report.biggestWin?.name == "movie.mp4")
        #expect(report.bestRatio?.name == "icon.png")
        #expect(report.files == 3)
        #expect(report.alreadyOptimal == 1)
        #expect(report.byKind[.video]?.files == 1 && report.byKind[.image]?.files == 2)
        #expect(report.byFormat.first?.format == "mp4")
    }

    @Test func `every Mac counts, and the same Mac name is combined`() {
        let a = Self.file([Self.event(0, 1000, 500)], device: "MacBook")
        let b = Self.file([Self.event(0, 3000, 1000)], device: "iMac")
        let report = StatsReport(files: [a, b], now: Self.now, calendar: Self.calendar).report(for: .all)
        #expect(report.saved == 2500)
        #expect(report.byDevice.map(\.name) == ["iMac", "MacBook"])
    }

    @Test func `buckets cover the period with no gaps`() {
        let file = Self.file([Self.event(0, 1000, 0, hour: -1), Self.event(1, 500, 0)])
        let report = StatsReport(files: [file], now: Self.now, calendar: Self.calendar)
        let day = report.report(for: .day)
        #expect(day.buckets.count == 24 && day.bucketUnit == .hour)
        #expect(day.buckets[14].saved == 1000)
        let week = report.report(for: .week)
        #expect(week.buckets.count == 7)
        #expect(week.buckets[4].saved == 500 && week.buckets[5].saved == 1000) // Friday, Saturday
        #expect(report.report(for: .month).buckets.count == 30)
        #expect(report.report(for: .year).buckets.count == 12)
    }

    @Test func `streaks count consecutive days and survive until today ends`() {
        let file = Self.file([1, 2, 3, 10, 11, 12, 13, 14].map { Self.event(Double($0), 1000, 500) })
        let lifetime = StatsReport(files: [file], now: Self.now, calendar: Self.calendar).lifetime()
        #expect(lifetime.currentStreak == 3) // yesterday back to 3 days ago; today not done yet
        #expect(lifetime.longestStreak == 5)
        #expect(lifetime.bestDay?.saved == 500)
    }

    @Test func `old events fold into archived totals`() {
        var file = StatsFile(deviceID: "a", deviceName: "Mac")
        file.append((0..<(StatsFile.maxEvents + 10)).map { _ in Self.event(1, 100, 50) })
        #expect(file.events.count == StatsFile.maxEvents)
        #expect(file.archived.files == 10 && file.archived.saved == 500)
        let report = StatsReport(files: [file], now: Self.now, calendar: Self.calendar)
        #expect(report.report(for: .all).files == StatsFile.maxEvents + 10)
        #expect(report.lifetime().saved == (StatsFile.maxEvents + 10) * 50)
    }

    @Test func `merging this Mac's local file skips duplicates`() {
        let shared = Self.event(1, 100, 50)
        var synced = Self.file([shared])
        synced.merge(Self.file([shared, Self.event(2, 300, 100)]))
        #expect(synced.events.count == 2)
    }

    @Test func `files round trip, and unknown kinds from newer versions still load`() throws {
        let file = Self.file([Self.event(0, 1000, 400, kind: .svg, format: "svg", source: .folder)])
        #expect(try JSONDecoder().decode(StatsFile.self, from: JSONEncoder().encode(file)) == file)

        let newer = #"{"deviceID":"x","events":[{"d":0,"k":"hologram","s":"teleport","o":10,"n":5}]}"#
        let decoded = try JSONDecoder().decode(StatsFile.self, from: Data(newer.utf8))
        #expect(decoded.events.first?.kind == .image && decoded.events.first?.source == .manual)
    }

    @Test func `restoring an original removes just that file's stat`() {
        let kept = Self.event(1, 100, 50, name: "a.png")
        let restored = Self.event(1, 900, 300, name: "b.png")
        var file = Self.file([kept, restored])
        file.remove([restored])
        #expect(file.events == [kept])
    }

    @Test func `kinds come from the extension`() {
        #expect(StatKind(fileExtension: "MOV") == .video)
        #expect(StatKind(fileExtension: "m4a") == .audio)
        #expect(StatKind(fileExtension: "heic") == .image)
        #expect(StatKind(fileExtension: "pdf") == .pdf)
    }
}
