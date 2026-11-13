import AppKit
import SquishKit
import SwiftUI

struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @ViewState private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            recents
            Divider().padding(.horizontal, 12)
            actions
        }
        .frame(width: 320)
        .dropDestination(for: URL.self) { urls, _ in
            model.optimize(urls.filter(\.isFileURL))
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.brand, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Theme.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(Text("Drop to optimize").font(.system(size: 15, weight: .semibold, design: .rounded)))
                    .padding(6)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var store = model.settings
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Squish").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary).contentTransition(.opacity)
                }
                Spacer()
                Toggle("Automatic optimization", isOn: Binding(get: { !model.isPaused }, set: { model.isPaused = !$0 }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(model.isPaused ? "Resume automatic optimization" : "Pause automatic optimization")
            }
            HStack(spacing: 6) {
                Toggle("Clipboard", systemImage: "doc.on.clipboard", isOn: $store.settings.clipboardEnabled)
                Toggle("Folders", systemImage: "folder", isOn: $store.settings.foldersEnabled)
            }
            .toggleStyle(ChipToggleStyle())
            .disabled(model.isPaused)
            if model.clipboard.accessDenied, store.settings.clipboardEnabled {
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                } label: {
                    Label("Squish can't read the clipboard. Allow it in Privacy & Security.", systemImage: "hand.raised.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    private var status: String {
        if model.activeJobs > 0 { return "Optimizing \(model.activeJobs) file\(model.activeJobs == 1 ? "" : "s")…" }
        if model.isPaused { return "Paused" }
        let saved = model.recents.reduce(0) { $0 + $1.saved }
        return saved > 0 ? "Saved \(Format.bytes(saved)) so far" : "Ready"
    }

    // MARK: Recents

    @ViewBuilder
    private var recents: some View {
        if model.recents.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Copy an image or drop files here to make them smaller.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 24)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.recents) { RecentRow(result: $0) }
                    }
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .padding(.top, 4)
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 0) {
            MenuRow(title: "Optimize Files…", shortcut: "⌘O") {
                dismiss()
                model.chooseFilesToOptimize()
            }
            .keyboardShortcut("o")
            MenuRow(title: "Settings…", shortcut: "⌘,") {
                dismiss()
                openSettings()
                NSApp.activate()
            }
            .keyboardShortcut(",")
            MenuRow(title: "Quit Squish", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(6)
    }
}

private struct RecentRow: View {
    let result: OptimizationResult
    @ViewState private var isHovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([result.file])
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: result.file.path))
                    .resizable()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.file.lastPathComponent)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(Format.bytes(result.newSize)), was \(Format.bytes(result.originalSize))")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("−" + Format.percentSaved(before: result.originalSize, after: result.newSize))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.brand)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Show in Finder")
    }
}

/// A native-looking menu item: full-width, highlights on hover.
private struct MenuRow: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @ViewState private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(shortcut).font(.system(size: 12)).foregroundStyle(isHovering ? .white.opacity(0.8) : .secondary)
            }
            .foregroundStyle(isHovering ? .white : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isHovering ? Theme.brand : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct ChipToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(configuration.isOn ? Theme.brand : .secondary)
                .background(
                    configuration.isOn ? Theme.brand.opacity(0.14) : Color.primary.opacity(0.05),
                    in: Capsule()
                )
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
