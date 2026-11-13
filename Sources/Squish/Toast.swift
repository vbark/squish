import AppKit
import Observation
import SquishKit
import SwiftUI
import UserNotifications

struct ToastContent: Identifiable {
    enum Body {
        case saved(before: Int, after: Int, note: String?)
        case message(String)
        case failure(String)
    }

    let id = UUID()
    var title: String
    var body: Body
    var restore: (() -> Void)?

    init(title: String, body: Body, restore: (() -> Void)? = nil) {
        self.title = title
        self.body = body
        self.restore = restore
    }

    init(results: [OptimizationResult], restore: (() -> Void)?) {
        self.restore = restore
        let replaced = results.filter(\.improved)
        let failed = results.compactMap(\.error)
        if results.count == 1, let result = results.first {
            title = result.file.lastPathComponent
            if let error = result.error {
                body = .failure(error.localizedDescription)
            } else if result.improved {
                body = .saved(before: result.originalSize, after: result.newSize, note: nil)
            } else {
                body = .message("Already as small as it gets. Left unchanged.")
            }
            return
        }
        title = "\(results.count) files"
        if replaced.isEmpty {
            body = failed.first.map { .failure("None optimized. \($0.localizedDescription)") }
                ?? .message("All already optimized. Nothing changed.")
        } else {
            let note = failed.isEmpty ? nil : "\(failed.count) couldn't be optimized: \(failed[0].localizedDescription)"
            body = .saved(
                before: replaced.reduce(0) { $0 + $1.originalSize },
                after: replaced.reduce(0) { $0 + $1.newSize },
                note: note
            )
        }
    }

    /// SVG conversions: name the PNGs that were made.
    init(svgResults results: [OptimizationResult]) {
        let made = results.filter { $0.error == nil }
        title = made.count == 1 ? made[0].file.lastPathComponent : "\(made.count) PNGs"
        if let error = results.compactMap(\.error).first {
            body = .failure(made.isEmpty ? error.localizedDescription : "\(results.count - made.count) failed: \(error.localizedDescription)")
        } else {
            let pixels = made.count == 1 ? Self.pixelSize(of: made[0].file) : nil
            body = .message("Created next to the SVG\(made.count == 1 ? "" : "s")" + (pixels.map { ", \($0)" } ?? "") + ".")
        }
    }

    private static func pixelSize(of url: URL) -> String? {
        guard let image = NSImageRep(contentsOf: url) else { return nil }
        return "\(image.pixelsWide) × \(image.pixelsHigh) px, \(Format.bytes(Pipeline.fileSize(url)))"
    }

    /// Plain text for system notifications.
    var summary: String {
        switch body {
        case .saved(let before, let after, let note):
            "\(Format.percentSaved(before: before, after: after)) smaller, now \(Format.bytes(after)). " + (note ?? "")
        case .message(let text), .failure(let text):
            text
        }
    }
}

enum Format {
    static func bytes(_ count: Int) -> String {
        count.formatted(.byteCount(style: .file))
    }

    static func percentSaved(before: Int, after: Int) -> String {
        guard before > 0 else { return "0%" }
        return (Double(before - after) / Double(before)).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Clop-style floating card under the menu bar. Stays while hovered, otherwise leaves after 3 s.
@Observable
final class ToastPresenter {
    private(set) var content: ToastContent?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    var isHovering = false {
        didSet { isHovering ? dismissTask?.cancel() : scheduleDismiss() }
    }

    func show(_ content: ToastContent, style: ToastStyle) {
        // Notifications need a real app bundle; `swift run` falls back to the panel.
        if style == .notification, Bundle.main.bundleIdentifier != nil {
            notify(content)
            return
        }
        self.content = content
        let panel = panel ?? makePanel()
        self.panel = panel
        if let host = panel.contentView {
            host.layoutSubtreeIfNeeded()
            panel.setContentSize(host.fittingSize)
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 10, y: frame.maxY - 8))
        }
        panel.orderFrontRegardless()
        scheduleDismiss()
    }

    func dismiss() {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        content = nil
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: ToastView(presenter: self))
        return panel
    }

    private func notify(_ content: ToastContent) {
        let title = content.title, body = content.summary, id = content.id.uuidString
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let notification = UNMutableNotificationContent()
            notification.title = title
            notification.body = body
            try? await center.add(UNNotificationRequest(identifier: id, content: notification, trigger: nil))
        }
    }
}

struct ToastView: View {
    let presenter: ToastPresenter

    var body: some View {
        if let content = presenter.content {
            ToastCard(content: content) { presenter.dismiss() }
                .id(content.id) // fresh state, so the bar animates for every result
                .onHover { presenter.isHovering = $0 }
                .padding(10) // room for the shadow
        }
    }
}

private struct ToastCard: View {
    let content: ToastContent
    let close: () -> Void
    @ViewState private var squished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(content.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                if let restore = content.restore {
                    Button("Restore Original") {
                        restore()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .medium))
                }
            }
            switch content.body {
            case .saved(let before, let after, let note):
                saved(before: before, after: after, note: note)
            case .message(let text):
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            case .failure(let text):
                Label {
                    Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture(perform: close)
        .accessibilityElement(children: .combine)
    }

    private func saved(before: Int, after: Int, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text("−" + Format.percentSaved(before: before, after: after))
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.brand)
                    .fixedSize()
                VStack(alignment: .leading, spacing: 6) {
                    SquishBar(fraction: squished ? Double(after) / Double(max(before, 1)) : 1)
                    Text("\(Format.bytes(after)), was \(Format.bytes(before))")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .onAppear {
            // The one motion in the app: the bar squishes from the original size to the new one.
            withAnimation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.55).delay(0.12)) {
                squished = true
            }
        }
    }
}

/// Track = original size, fill = new size.
struct SquishBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Theme.brand)
                    .frame(width: max(6, geometry.size.width * min(1, fraction)))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
