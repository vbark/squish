import AppKit
import SwiftUI

/// Tokyo Night in dark mode, Tokyo Night Day in light mode.
enum Tokyo {
    static let background = dynamic(dark: 0x1A1B26, light: 0xE1E2E7)
    static let backgroundDeep = dynamic(dark: 0x16161E, light: 0xD0D5E3)
    static let foreground = dynamic(dark: 0xC0CAF5, light: 0x3760BF)
    static let secondary = dynamic(dark: 0xA9B1D6, light: 0x6172B0)
    static let muted = dynamic(dark: 0x787FA6, light: 0x7A82AD)
    static let hairline = dynamic(dark: 0x414868, light: 0xA8AECB, alpha: 0.45)
    static let blue = dynamic(dark: 0x7AA2F7, light: 0x2E7DE9)
    static let cyan = dynamic(dark: 0x7DCFFF, light: 0x007197)
    static let teal = dynamic(dark: 0x73DACA, light: 0x118C74)
    static let purple = dynamic(dark: 0xBB9AF7, light: 0x9854F1)
    static let green = dynamic(dark: 0x9ECE6A, light: 0x587539)
    static let yellow = dynamic(dark: 0xE0AF68, light: 0x8C6C3E)
    static let orange = dynamic(dark: 0xFF9E64, light: 0xB15C00)
    static let red = dynamic(dark: 0xF7768E, light: 0xF52A65)
    /// Glyphs on an accent-colored tile.
    static let onAccent = dynamic(dark: 0x16161E, light: 0xFFFFFF)

    private static func dynamic(dark: UInt32, light: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        })
    }
}

/// Night sky behind the glass: the Tokyo Night base with soft blue, purple and cyan glows for the glass to refract.
struct TokyoBackdrop: View {
    var body: some View {
        ZStack {
            Tokyo.background
            RadialGradient(colors: [Tokyo.blue.opacity(0.32), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Tokyo.purple.opacity(0.28), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 560)
            RadialGradient(colors: [Tokyo.cyan.opacity(0.12), .clear], center: UnitPoint(x: 0.75, y: 0.1), startRadius: 0, endRadius: 320)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Liquid Glass on macOS 26 and later, a translucent material before that.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            let glass = tint.map { Glass.regular.tint($0) } ?? .regular
            self.glassEffect(interactive ? glass.interactive() : glass, in: shape)
        } else {
            self
                .background((tint ?? .clear).opacity(0.6), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Tokyo.hairline, lineWidth: 0.5))
        }
    }
}

/// Lets the content run under the title bar, so the backdrop fills the whole window.
/// The Settings scene owns its window and toolbar and re-applies its own style, so on macOS 15 and later
/// this uses SwiftUI's toolbar modifiers; the AppKit settings are a fallback for macOS 14.
struct TransparentTitleBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .background(WindowProbe())
        } else {
            content.background(WindowProbe())
        }
    }

    private struct WindowProbe: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { Probe() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        private final class Probe: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window else { return }
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
                window.isMovableByWindowBackground = true
                window.titlebarSeparatorStyle = .none
                // An empty unified toolbar makes the title bar taller, which sets the traffic lights
                // in from the sidebar's rounded corner.
                if window.toolbar == nil {
                    window.toolbar = NSToolbar(identifier: "SquishSettings")
                }
                window.toolbarStyle = .unified
            }
        }
    }
}

// MARK: Building blocks

/// A rounded glass card holding rows separated by hairlines.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: 18, tint: Tokyo.backgroundDeep.opacity(0.35))
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Tokyo.hairline).frame(height: 0.5).padding(.leading, 16)
    }
}

/// Title (and optional detail) on the left, a control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Tokyo.foreground)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Tokyo.muted)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 46)
    }
}

/// A small heading above a card.
struct CardHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(Tokyo.muted)
            .padding(.leading, 16)
    }
}

/// Explanatory text under a card.
struct CardFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Tokyo.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
    }
}

/// A capsule that toggles on click, tinted when on.
struct Chip: View {
    let title: String
    @Binding var isOn: Bool
    var color: Color = Tokyo.blue

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(title)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .foregroundStyle(isOn ? color : Tokyo.muted)
                .background(Capsule().fill(isOn ? color.opacity(0.18) : Tokyo.backgroundDeep.opacity(0.55)))
                .overlay(Capsule().strokeBorder(isOn ? color.opacity(0.55) : Tokyo.hairline, lineWidth: 0.75))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .animation(.snappy(duration: 0.18), value: isOn)
    }
}

/// A rounded tile with an SF Symbol, like the icons in System Settings.
struct IconTile: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Tokyo.onAccent)
            )
    }
}

/// A secondary action drawn as a glass capsule.
struct GlassButton: View {
    let title: String
    var systemImage: String?
    var color: Color = Tokyo.blue
    /// Smaller, for actions inside a row.
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 4 : 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(compact ? .caption.weight(.semibold) : .callout.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassPanel(cornerRadius: 100, tint: color.opacity(0.12), interactive: true)
    }
}

/// Lays children out left to right and wraps to a new line when the next one does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// A segmented control in the same style as `Chip`: a dark track with a tinted pill that slides to the selection.
struct GlassSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var color: Color = Tokyo.blue
    /// Same width for every segment, so a column of these lines up.
    var segmentWidth: CGFloat?
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                segment(options[index].value, options[index].title)
            }
        }
        .padding(3)
        .background(Capsule().fill(Tokyo.backgroundDeep.opacity(0.55)))
        .overlay(Capsule().strokeBorder(Tokyo.hairline, lineWidth: 0.75))
        .fixedSize()
    }

    private func segment(_ value: Value, _ title: String) -> some View {
        let isSelected = value == selection
        return Button {
            withAnimation(.snappy(duration: 0.22)) { selection = value }
        } label: {
            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? color : Tokyo.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(width: segmentWidth)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(color.opacity(0.2))
                            .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 0.75))
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
