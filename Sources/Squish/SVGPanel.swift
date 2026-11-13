import AppKit
import SquishKit
import SwiftUI

/// The small popup that asks for a scale before converting one or more SVGs.
final class SVGPanelController {
    private var panel: NSPanel?

    func present(_ files: [URL], defaultScale: Double, naming: SVGNaming, convert: @escaping (Double) -> Void) {
        panel?.close()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let close: () -> Void = { [weak panel] in panel?.close() }
        panel.contentView = NSHostingView(rootView: SVGScaleView(
            files: files, scale: defaultScale, naming: naming,
            cancel: close,
            convert: { scale in
                close()
                convert(scale)
            }
        ))
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        panel.center()
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct SVGScaleView: View {
    let files: [URL]
    let naming: SVGNaming
    let cancel: () -> Void
    let convert: (Double) -> Void

    @ViewState private var preset: Double
    @ViewState private var custom = ""
    private let sizes: [URL: CGSize]

    private static let customTag = -1.0

    init(files: [URL], scale: Double, naming: SVGNaming, cancel: @escaping () -> Void, convert: @escaping (Double) -> Void) {
        self.files = files
        self.naming = naming
        self.cancel = cancel
        self.convert = convert
        let isPreset = SVG.presetScales.contains(scale)
        _preset = ViewState(initialValue: isPreset ? scale : Self.customTag)
        _custom = ViewState(initialValue: isPreset ? "" : scale.formatted())
        sizes = Dictionary(uniqueKeysWithValues: files.compactMap { url in
            (try? SVG.intrinsicSize(of: url)).map { (url, $0) }
        })
    }

    /// nil while the custom field holds something unusable.
    private var scale: Double? {
        guard preset == Self.customTag else { return preset }
        let value = Double(custom.replacingOccurrences(of: ",", with: "."))
        return value.flatMap { (0.05...20).contains($0) ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(files.count == 1 ? "Convert to PNG" : "Convert \(files.count) SVGs to PNG")
                .font(.system(size: 15, weight: .bold, design: .rounded))

            HStack(spacing: 8) {
                Picker("Scale", selection: $preset) {
                    ForEach(SVG.presetScales, id: \.self) { Text("\($0.formatted())×").tag($0) }
                    Text("Custom").tag(Self.customTag)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if preset == Self.customTag {
                    TextField("1.5", text: $custom)
                        .frame(width: 52)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { if let scale { convert(scale) } }
                    Text("×").foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(files, id: \.self) { file in
                        HStack {
                            Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 12)
                            dimensions(for: file)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)

            if let scale, let first = files.first, let size = sizes[first] {
                Text("Saved next to each SVG, for example \(SVG.outputName(for: first, scale: scale, naming: naming, pixels: SVG.pixelSize(size, scale: scale))).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Convert") { if let scale { convert(scale) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(scale == nil || sizes.isEmpty)
            }
        }
        .padding(20)
        .padding(.top, 8)
        .frame(width: 400)
    }

    @ViewBuilder
    private func dimensions(for file: URL) -> some View {
        if let size = sizes[file] {
            if let scale {
                let pixels = SVG.pixelSize(size, scale: scale)
                Text("\(pixels.width) × \(pixels.height) px")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: scale)
            } else {
                Text("Enter a scale").foregroundStyle(.secondary)
            }
        } else {
            Text("Not a readable SVG").foregroundStyle(.orange)
        }
    }
}

/// Finder's Services menu entry ("Convert SVG to PNG with Squish"), declared in Info.plist.
final class ServiceProvider: NSObject {
    private let handler: ([URL]) -> Void

    init(handler: @escaping ([URL]) -> Void) {
        self.handler = handler
    }

    @objc func convertSVG(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        handler(urls)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var services: ServiceProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let services = ServiceProvider { [model] urls in model.convertSVGs(urls) }
        self.services = services
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }
}
