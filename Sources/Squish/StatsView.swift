import AppKit
import SquishKit
import SwiftUI

/// Data colors for the stats charts. Tokyo Night hues stepped into the chart lightness band and validated
/// for color-vision deficiency in both modes; the order (image, video, audio, pdf, svg) is part of that check.
enum ChartColor {
    static func kind(_ kind: StatKind) -> Color {
        switch kind {
        case .image: dynamic(dark: 0x3987E5, light: 0x2A78D6)
        case .video: dynamic(dark: 0xD95926, light: 0xEB6834)
        case .audio: dynamic(dark: 0x199E70, light: 0x1BAF7A)
        case .pdf: dynamic(dark: 0x9085E9, light: 0x6250D6)
        case .svg: dynamic(dark: 0xD55181, light: 0xE87BA4)
        }
    }

    /// Single-hue activity color (bars and heatmap).
    static let activity = Tokyo.green

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

extension StatKind {
    var title: String {
        switch self {
        case .image: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .svg: "SVG → PNG"
        }
    }
}

extension StatSource {
    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .folder: "Watched folders"
        case .manual: "Menu and drag and drop"
        case .shortcut: "Keyboard shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .folder: "folder"
        case .manual: "hand.point.up.left"
        case .shortcut: "command"
        }
    }
}

extension StatPeriod {
    var title: String {
        switch self {
        case .day: "Today"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .all: "All time"
        }
    }

    /// "Saved this week"
    var phrase: String {
        switch self {
        case .day: "today"
        case .week: "this week"
        case .month: "this month"
        case .year: "this year"
        case .all: "in total"
        }
    }
}

// MARK: Page

struct StatsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var store
    @ViewState private var period = StatPeriod.week
    @ViewState private var confirmReset = false

    var body: some View {
        let report = model.stats.report
        let current = report.report(for: period)
        let lifetime = report.lifetime()

        GlassSegmented(selection: $period, options: StatPeriod.allCases.map { ($0, $0.title) },
                       color: ChartColor.activity, segmentWidth: 78)
            .padding(.bottom, 4)

        if report.isEmpty {
            EmptyStats()
        } else {
            HeroCard(report: current)
            HStack(spacing: 8) {
                StatTile(systemImage: "photo.stack", color: Tokyo.blue, value: current.files.formatted(), label: "files squished")
                StatTile(systemImage: "checkmark.seal", color: Tokyo.teal, value: current.alreadyOptimal.formatted(),
                         label: "already perfect")
                StatTile(systemImage: "timer", color: Tokyo.purple, value: Format.duration(milliseconds: current.milliseconds),
                         label: "spent squishing")
                StatTile(systemImage: "flame.fill", color: Tokyo.orange,
                         value: "\(lifetime.currentStreak) day\(lifetime.currentStreak == 1 ? "" : "s")",
                         label: "streak · best \(lifetime.longestStreak)")
            }
            HStack(alignment: .top, spacing: 8) {
                KindBreakdown(report: current)
                ActivityChart(report: current)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 10)
            CardHeader(title: "Records \(period.phrase)")
            HStack(spacing: 8) {
                RecordTile(title: "Heavyweight", systemImage: "scalemass.fill", color: Tokyo.orange, event: current.heaviest) { event in
                    Format.bytes(event.originalSize)
                }
                RecordTile(title: "Best squish", systemImage: "trophy.fill", color: Tokyo.yellow, event: current.bestRatio) { event in
                    "−" + Format.percentSaved(before: event.originalSize, after: event.newSize)
                }
                RecordTile(title: "Biggest win", systemImage: "bolt.fill", color: Tokyo.cyan, event: current.biggestWin) { event in
                    "−" + Format.bytes(event.saved)
                }
            }

            Spacer().frame(height: 10)
            CardHeader(title: "Habits")
            Habits(current: current, lifetime: lifetime)

            Spacer().frame(height: 10)
            CardHeader(title: "Last 30 weeks")
            GlassCard {
                Heatmap(daily: lifetime.daily, now: report.now, calendar: report.calendar)
                    .padding(16)
            }

            if current.byDevice.count > 1 || store.syncFolder != nil {
                Spacer().frame(height: 10)
                CardHeader(title: "By Mac")
                DeviceList(devices: current.byDevice)
            }

            Spacer().frame(height: 6)
            HStack(alignment: .top) {
                CardFooter(store.syncFolder == nil
                    ? "Stats stay on this Mac. Turn on Sync settings in General to add up every Mac's numbers."
                    : "Stats sync through your sync folder. Each Mac keeps its own file, so nothing gets overwritten.")
                Spacer()
                GlassButton(title: "Reset This Mac…", color: Tokyo.red, compact: true) { confirmReset = true }
            }
            .confirmationDialog("Reset this Mac's stats?", isPresented: $confirmReset) {
                Button("Reset", role: .destructive) { model.stats.resetThisMac() }
            } message: {
                Text("Squish forgets every file it optimized on this Mac. Other Macs keep their stats. Your files are not touched.")
            }
        }
        Color.clear.frame(height: 0)
            .task {
                while !Task.isCancelled {
                    model.stats.reload()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
    }
}

// MARK: Hero

private struct HeroCard: View {
    let report: PeriodReport

    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SAVED \(report.period.phrase.uppercased())")
                        .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(Tokyo.muted)
                    Text(Format.bytes(report.saved))
                        .font(.system(size: 46, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(LinearGradient(colors: [Tokyo.cyan, Tokyo.purple], startPoint: .leading, endPoint: .trailing))
                        .contentTransition(.numericText())
                    if report.originalSize > 0 {
                        SquishBar(fraction: 1 - report.averageReduction)
                            .frame(width: 220)
                        Text("\(Format.bytes(report.originalSize)) → \(Format.bytes(report.originalSize - report.saved)) · "
                             + "\(Format.percentSaved(before: report.originalSize, after: report.originalSize - report.saved)) smaller")
                            .font(.callout).foregroundStyle(Tokyo.secondary).monospacedDigit()
                    } else {
                        Text("Nothing squished \(report.period.phrase) yet.").font(.callout).foregroundStyle(Tokyo.secondary)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 10) {
                    FunFact(systemImage: "externaldrive.fill", color: Tokyo.blue,
                            value: Format.count(Double(report.saved) / 1_474_560), label: "floppy disks")
                    FunFact(systemImage: "wifi", color: Tokyo.teal,
                            value: Format.duration(milliseconds: report.saved * 8 / 10_000), label: "less waiting on hotel Wi-Fi")
                    FunFact(systemImage: "photo", color: Tokyo.purple,
                            value: Format.count(Double(report.saved) / 3_000_000), label: "iPhone photos' worth")
                }
                .padding(.top, 4)
            }
            .padding(18)
        }
        .animation(.snappy, value: report.saved)
    }
}

private struct FunFact: View {
    let systemImage: String
    let color: Color
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(Circle().fill(color.opacity(0.15)))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.callout.weight(.semibold)).foregroundStyle(Tokyo.foreground).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(Tokyo.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Tiles

private struct StatTile: View {
    let systemImage: String
    let color: Color
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Tokyo.foreground)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(Tokyo.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassPanel(cornerRadius: 16, tint: Tokyo.backgroundDeep.opacity(0.35))
        .accessibilityElement(children: .combine)
    }
}

private struct RecordTile: View {
    let title: String
    let systemImage: String
    let color: Color
    let event: StatEvent?
    let headline: (StatEvent) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Spacer(minLength: 4)
                if let event {
                    Text(event.date.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.caption2).foregroundStyle(Tokyo.muted)
                }
            }
            if let event {
                Text(headline(event))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Tokyo.foreground)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(event.name)
                    .font(.callout)
                    .foregroundStyle(Tokyo.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(event.name)
                Text("\(Format.bytes(event.originalSize)) → \(Format.bytes(event.newSize))")
                    .font(.caption)
                    .foregroundStyle(Tokyo.muted)
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                Text("—").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Tokyo.muted)
                Text("No files yet").font(.callout).foregroundStyle(Tokyo.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassPanel(cornerRadius: 16, tint: Tokyo.backgroundDeep.opacity(0.35))
        .accessibilityElement(children: .combine)
    }
}

// MARK: By kind

/// One labeled bar per kind. Every bar carries its name and value as text, so color is never the only cue.
private struct KindBreakdown: View {
    let report: PeriodReport

    var body: some View {
        let kinds = StatKind.allCases.filter { (report.byKind[$0]?.files ?? 0) > 0 }
        let maxSaved = max(1, kinds.map { report.byKind[$0]?.saved ?? 0 }.max() ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            Text("By kind").font(.callout.weight(.semibold)).foregroundStyle(Tokyo.foreground)
            if kinds.isEmpty {
                Text("Nothing yet \(report.period.phrase).").font(.callout).foregroundStyle(Tokyo.muted)
            }
            ForEach(kinds, id: \.self) { kind in
                let total = report.byKind[kind] ?? KindTotal()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(ChartColor.kind(kind)).frame(width: 7, height: 7)
                        Text(kind.title).font(.callout).foregroundStyle(Tokyo.foreground)
                        Text("\(total.files)").font(.caption).foregroundStyle(Tokyo.muted).monospacedDigit()
                        Spacer(minLength: 6)
                        Text(Format.bytes(total.saved)).font(.callout.weight(.medium)).foregroundStyle(Tokyo.foreground).monospacedDigit()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Tokyo.hairline.opacity(0.5))
                            Capsule().fill(ChartColor.kind(kind))
                                .frame(width: max(4, geometry.size.width * Double(total.saved) / Double(maxSaved)))
                        }
                    }
                    .frame(height: 6)
                }
                .help("\(kind.title): \(total.files) file\(total.files == 1 ? "" : "s"), \(Format.bytes(total.saved)) saved")
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel(cornerRadius: 18, tint: Tokyo.backgroundDeep.opacity(0.35))
    }
}

// MARK: Activity

/// Bytes saved per hour, day or month across the period. One series, so no legend; hover a bar for its numbers.
private struct ActivityChart: View {
    let report: PeriodReport

    var body: some View {
        let peak = report.buckets.map(\.saved).max() ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity").font(.callout.weight(.semibold)).foregroundStyle(Tokyo.foreground)
                Spacer()
                if peak > 0 {
                    Text("peak \(Format.bytes(peak))").font(.caption).foregroundStyle(Tokyo.muted).monospacedDigit()
                }
            }
            HStack(alignment: .bottom, spacing: report.buckets.count > 20 ? 1.5 : 3) {
                // Fills the card's height, so it lines up with the "By kind" card beside it.
                ForEach(report.buckets, id: \.start) { bucket in
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous)
                                .fill(bucket.saved > 0 ? ChartColor.activity : Tokyo.hairline.opacity(0.6))
                                .frame(height: bucket.saved > 0
                                    ? max(3, geometry.size.height * Double(bucket.saved) / Double(max(peak, 1)))
                                    : 1.5)
                        }
                    }
                    .contentShape(Rectangle())
                    .help("\(label(for: bucket.start, long: true)): \(Format.bytes(bucket.saved)) saved, \(bucket.files) file\(bucket.files == 1 ? "" : "s")")
                }
            }
            .frame(minHeight: 96, maxHeight: .infinity)
            HStack {
                if let first = report.buckets.first { axisLabel(first.start) }
                Spacer()
                if report.buckets.count > 2 { axisLabel(report.buckets[report.buckets.count / 2].start) }
                Spacer()
                if let last = report.buckets.last { axisLabel(last.start) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel(cornerRadius: 18, tint: Tokyo.backgroundDeep.opacity(0.35))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity \(report.period.phrase), peak \(Format.bytes(peak))")
    }

    private func axisLabel(_ date: Date) -> some View {
        Text(label(for: date, long: false)).font(.caption2).foregroundStyle(Tokyo.muted)
    }

    private func label(for date: Date, long: Bool) -> String {
        switch report.bucketUnit {
        case .hour: date.formatted(.dateTime.hour())
        case .month: long ? date.formatted(.dateTime.month(.wide).year()) : date.formatted(.dateTime.month(.abbreviated))
        default:
            report.period == .week && !long
                ? date.formatted(.dateTime.weekday(.abbreviated))
                : date.formatted(.dateTime.weekday(long ? .wide : .abbreviated).day().month(.abbreviated))
        }
    }
}

// MARK: Habits

private struct Habits: View {
    let current: PeriodReport
    let lifetime: LifetimeReport

    var body: some View {
        GlassCard {
            if let hour = lifetime.favoriteHour {
                HabitRow(systemImage: Self.timeIcon(hour), color: Tokyo.yellow, title: Self.timeTitle(hour),
                         detail: "Most files get squished around \(Self.hourText(hour)).")
                CardDivider()
            }
            if let best = lifetime.bestDay {
                HabitRow(systemImage: "star.fill", color: Tokyo.orange, title: "Best day: \(Format.bytes(best.saved))",
                         detail: best.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                CardDivider()
            }
            if let top = current.byFormat.first, current.saved > 0 {
                HabitRow(systemImage: "doc.richtext", color: Tokyo.blue, title: "Top format: \(top.format.uppercased())",
                         detail: "\(Format.percent(Double(top.total.saved) / Double(current.saved))) of what you saved \(current.period.phrase), across \(top.total.files) file\(top.total.files == 1 ? "" : "s").")
                CardDivider()
            }
            if let source = current.bySource.max(by: { $0.value.files < $1.value.files }), current.files > 0 {
                HabitRow(systemImage: source.key.systemImage, color: Tokyo.teal, title: "Mostly from: \(source.key.title)",
                         detail: "\(Format.percent(Double(source.value.files) / Double(current.files))) of files \(current.period.phrase).")
                CardDivider()
            }
            if let first = lifetime.firstDate {
                HabitRow(systemImage: "sparkles", color: Tokyo.purple, title: "Squishing since \(first.formatted(.dateTime.day().month(.wide).year()))",
                         detail: "\(Format.bytes(lifetime.saved)) saved across \(lifetime.files.formatted()) files, on every Mac.")
            }
        }
    }

    static func timeTitle(_ hour: Int) -> String {
        switch hour {
        case 5..<9: "Early bird"
        case 9..<12: "Morning squisher"
        case 12..<17: "Afternoon squisher"
        case 17..<22: "Evening squisher"
        default: "Night owl"
        }
    }

    static func timeIcon(_ hour: Int) -> String {
        switch hour {
        case 5..<9: "sunrise.fill"
        case 9..<17: "sun.max.fill"
        case 17..<22: "sunset.fill"
        default: "moon.stars.fill"
        }
    }

    static func hourText(_ hour: Int) -> String {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)?.formatted(date: .omitted, time: .shortened) ?? "\(hour):00"
    }
}

private struct HabitRow: View {
    let systemImage: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(Tokyo.foreground)
                Text(detail).font(.caption).foregroundStyle(Tokyo.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Heatmap

/// One square per day, one column per week. A single hue from faint to full; hover a day for its numbers.
private struct Heatmap: View {
    let daily: [Date: Int]
    let now: Date
    let calendar: Calendar

    private static let weeks = 30
    private static let cell: CGFloat = 13
    private static let gap: CGFloat = 3

    var body: some View {
        let columns = weekColumns()
        let levels = thresholds(columns)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(row % 2 == 0 ? weekdaySymbol(row) : "")
                            .font(.system(size: 9))
                            .foregroundStyle(Tokyo.muted)
                            .frame(height: Self.cell)
                    }
                }
                HStack(spacing: Self.gap) {
                    ForEach(columns, id: \.self) { week in
                        VStack(spacing: Self.gap) {
                            ForEach(0..<7, id: \.self) { row in
                                let day = calendar.date(byAdding: .day, value: row, to: week)!
                                if day > now {
                                    Color.clear.frame(width: Self.cell, height: Self.cell)
                                } else {
                                    let saved = daily[calendar.startOfDay(for: day)] ?? 0
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(color(for: saved, thresholds: levels))
                                        .frame(width: Self.cell, height: Self.cell)
                                        .help("\(day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))): "
                                              + (saved > 0 ? "\(Format.bytes(saved)) saved" : "nothing squished"))
                                }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Spacer()
                Text("Less").font(.caption2).foregroundStyle(Tokyo.muted)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(level == 0 ? Tokyo.hairline.opacity(0.5) : ChartColor.activity.opacity(Self.opacity(level)))
                        .frame(width: 10, height: 10)
                }
                Text("More").font(.caption2).foregroundStyle(Tokyo.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily activity over the last \(Self.weeks) weeks")
    }

    /// Start of each week, oldest first, ending with the current week.
    private func weekColumns() -> [Date] {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        return (0..<Self.weeks).reversed().compactMap { calendar.date(byAdding: .weekOfYear, value: -$0, to: thisWeek) }
    }

    private func weekdaySymbol(_ row: Int) -> String {
        let index = (calendar.firstWeekday - 1 + row) % 7
        return calendar.veryShortWeekdaySymbols[index]
    }

    /// Quartiles of the days with activity, so each shade covers about a quarter of active days
    /// and one huge video day doesn't flatten every screenshot day into the same color.
    private func thresholds(_ columns: [Date]) -> [Int] {
        let first = columns.first ?? now
        let values = daily.filter { $0.key >= first && $0.value > 0 }.map(\.value).sorted()
        guard !values.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { values[min(values.count - 1, Int(Double(values.count) * $0))] }
    }

    private func color(for saved: Int, thresholds: [Int]) -> Color {
        guard saved > 0, !thresholds.isEmpty else { return Tokyo.hairline.opacity(0.5) }
        let level = 1 + thresholds.filter { saved > $0 }.count
        return ChartColor.activity.opacity(Self.opacity(level))
    }

    private static func opacity(_ level: Int) -> Double {
        [0, 0.25, 0.45, 0.7, 1][level]
    }
}

// MARK: Devices

private struct DeviceList: View {
    let devices: [DeviceTotal]

    var body: some View {
        GlassCard {
            if devices.isEmpty {
                Text("No files yet in this period.").font(.callout).foregroundStyle(Tokyo.muted).padding(16)
            }
            ForEach(Array(devices.enumerated()), id: \.element.name) { index, device in
                if index > 0 { CardDivider() }
                HStack(spacing: 12) {
                    Image(systemName: device.name == StatsStore.deviceName ? "laptopcomputer" : "desktopcomputer")
                        .foregroundStyle(Tokyo.cyan)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name + (device.name == StatsStore.deviceName ? " (this Mac)" : ""))
                            .foregroundStyle(Tokyo.foreground)
                        Text("\(device.files.formatted()) file\(device.files == 1 ? "" : "s")").font(.caption).foregroundStyle(Tokyo.muted)
                    }
                    Spacer()
                    Text(Format.bytes(device.saved)).font(.callout.weight(.semibold)).foregroundStyle(Tokyo.foreground).monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }
}

// MARK: Empty

private struct EmptyStats: View {
    var body: some View {
        GlassCard {
            VStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis.ascending")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(LinearGradient(colors: [Tokyo.cyan, Tokyo.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("No stats yet").font(.title3.weight(.semibold)).foregroundStyle(Tokyo.foreground)
                Text("Copy a screenshot, drop a file on the menu, or save one in a watched folder. Every byte Squish saves shows up here.")
                    .font(.callout)
                    .foregroundStyle(Tokyo.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        }
    }
}

// MARK: Formatting

extension Format {
    /// "850 ms", "12 s", "3 min 20 s", "2 h 5 min"
    static func duration(milliseconds: Int) -> String {
        if milliseconds < 1000 { return "\(milliseconds) ms" }
        return Duration.milliseconds(milliseconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
    }

    /// Whole numbers above 10, one decimal below: "0.4", "3.2", "853".
    static func count(_ value: Double) -> String {
        value >= 10 ? Int(value.rounded()).formatted() : value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
