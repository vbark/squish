import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SquishKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, stats, clipboard, folders, formats, svg, shortcuts, advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .stats: "Stats"
        case .clipboard: "Clipboard"
        case .folders: "Folders"
        case .formats: "Formats"
        case .svg: "SVG"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Startup, results and syncing between Macs."
        case .stats: "Everything Squish has saved you, on every Mac."
        case .clipboard: "Shrink media the moment you copy it."
        case .folders: "Optimize new files where they land."
        case .formats: "How hard each format gets squeezed."
        case .svg: "Turn SVGs into PNGs, by hand or automatically."
        case .shortcuts: "Act on the files selected in Finder, from the keyboard."
        case .advanced: "Performance, backups and logs."
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .stats: "chart.bar.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .folders: "folder.fill"
        case .formats: "photo.stack.fill"
        case .svg: "square.on.circle.fill"
        case .shortcuts: "command"
        case .advanced: "slider.horizontal.3"
        }
    }

    var color: Color {
        switch self {
        case .general: Tokyo.blue
        case .stats: Tokyo.green
        case .clipboard: Tokyo.teal
        case .folders: Tokyo.yellow
        case .formats: Tokyo.purple
        case .svg: Tokyo.orange
        case .shortcuts: Tokyo.cyan
        case .advanced: Tokyo.red
        }
    }
}

struct SettingsView: View {
    @ViewState private var page = SettingsPage.general

    /// Tall enough that every page fits without scrolling. Only a long folder list ever scrolls.
    static let size = CGSize(width: 800, height: 680)
    /// Height of the transparent unified title bar that holds the traffic lights.
    static let titleBarHeight: CGFloat = 52

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $page)
                .padding(10)
            PageScaffold(page: page) {
                switch page {
                case .general: GeneralPage()
                case .stats: StatsPage()
                case .clipboard: ClipboardPage()
                case .folders: FoldersPage()
                case .formats: FormatsPage()
                case .svg: SVGPage()
                case .shortcuts: ShortcutsPage()
                case .advanced: AdvancedPage()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TokyoBackdrop())
        .ignoresSafeArea()
        // The window adds the title bar on top of this; the content above runs up underneath it.
        .frame(width: Self.size.width, height: Self.size.height - Self.titleBarHeight)
        .modifier(TransparentTitleBar())
        .tint(Tokyo.blue)
        .toggleStyle(.switch)
    }
}

// MARK: Sidebar

private struct Sidebar: View {
    @Binding var selection: SettingsPage
    @Namespace private var highlight

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Room for the traffic lights.
            Spacer().frame(height: 40)
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [Tokyo.cyan, Tokyo.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("Squish").font(.title3.weight(.semibold)).foregroundStyle(Tokyo.foreground)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)

            ForEach(SettingsPage.allCases) { page in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = page }
                } label: {
                    HStack(spacing: 10) {
                        IconTile(systemImage: page.systemImage, color: page.color)
                        Text(page.title)
                            .foregroundStyle(selection == page ? Tokyo.foreground : Tokyo.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background {
                        if selection == page {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Tokyo.blue.opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Tokyo.blue.opacity(0.35), lineWidth: 0.75))
                                .matchedGeometryEffect(id: "selection", in: highlight)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == page ? .isSelected : [])
            }
            Spacer()
            if let version = Self.version {
                Text("Version \(version)")
                    .font(.caption2)
                    .foregroundStyle(Tokyo.muted)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 14)
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .glassPanel(cornerRadius: 22, tint: Tokyo.backgroundDeep.opacity(0.4))
    }
}

// MARK: Page scaffold

/// Page title, then the content. Falls back to scrolling only if the content cannot fit.
private struct PageScaffold<Content: View>: View {
    let page: SettingsPage
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                IconTile(systemImage: page.systemImage, color: page.color, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(page.title).font(.title2.weight(.semibold)).foregroundStyle(Tokyo.foreground)
                    Text(page.subtitle).font(.callout).foregroundStyle(Tokyo.secondary)
                }
            }
            .padding(.leading, 4)
            ViewThatFits(in: .vertical) {
                stack
                ScrollView { stack.padding(.bottom, 8) }
            }
        }
        .padding(.top, 34)
        .padding(.leading, 14)
        .padding(.trailing, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(page) // fresh state and a clean transition per page
        .transition(.opacity)
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 8) { content }
    }
}

/// Space between groups of cards on a page.
private struct GroupGap: View {
    var body: some View { Spacer().frame(height: 10) }
}

// MARK: General

private struct GeneralPage: View {
    @Environment(SettingsStore.self) private var store
    @ViewState private var loginError: String?

    var body: some View {
        @Bindable var store = store
        GlassCard {
            SettingRow(title: "Open at login", detail: loginError) {
                Toggle("Open at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { enable in
                        do {
                            try enable ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                ))
                .labelsHidden()
            }
        }
        GroupGap()
        CardHeader(title: "Results")
        GlassCard {
            SettingRow(title: "Show results as") {
                GlassSegmented(selection: $store.settings.toastStyle, options: [
                    (ToastStyle.panel, "Floating card"), (ToastStyle.notification, "Notification"),
                ])
            }
            CardDivider()
            SettingRow(title: "Play a sound when a file gets smaller") {
                Toggle("Sound", isOn: $store.settings.sounds).labelsHidden()
            }
        }
        GroupGap()
        SyncSection()
    }
}

private struct SyncSection: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        CardHeader(title: "Sync settings")
        GlassCard {
            if let folder = store.syncFolder {
                SettingRow(title: "Syncing to") {
                    Text((folder.path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(Tokyo.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(folder.path)
                }
                if let lastSynced = store.lastSynced {
                    CardDivider()
                    SettingRow(title: "Last synced") {
                        Text(lastSynced.formatted(date: .omitted, time: .shortened)).foregroundStyle(Tokyo.secondary)
                    }
                }
                CardDivider()
                HStack {
                    GlassButton(title: "Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([SettingsFile(folder: folder).url])
                    }
                    Spacer()
                    GlassButton(title: "Stop Syncing", color: Tokyo.red) { store.stopSync() }
                }
                .padding(12)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sync with").foregroundStyle(Tokyo.foreground).padding(.leading, 4)
                    FlowLayout(spacing: 8) {
                        if let iCloud = SettingsStore.iCloudFolder {
                            GlassButton(title: "iCloud Drive", systemImage: "icloud") { start(iCloud) }
                        }
                        ForEach(SettingsStore.oneDriveFolders, id: \.self) { folder in
                            GlassButton(title: oneDriveTitle(folder), systemImage: "cloud") { start(folder) }
                        }
                        GlassButton(title: "Choose Folder…", systemImage: "folder.badge.plus", action: chooseFolder)
                    }
                }
                .padding(12)
            }
            if let error = store.syncError {
                CardDivider()
                Text(error).font(.caption).foregroundStyle(Tokyo.red).padding(12)
            }
        }
        CardFooter("Keeps a settings.json file in the folder. Other Macs using the same folder pick up changes within 15 seconds. Pause, open at login and the sync folder stay on this Mac.")
            .confirmationDialog(
                "This folder already has Squish settings",
                isPresented: Binding(get: { store.pendingSync != nil }, set: { if !$0 { store.pendingSync = nil } }),
                presenting: store.pendingSync
            ) { pending in
                Button("Use Settings from the Folder") { store.commitSync(folder: pending.folder, useRemote: true) }
                Button("Replace with This Mac's Settings") { store.commitSync(folder: pending.folder, useRemote: false) }
                Button("Cancel", role: .cancel) { store.pendingSync = nil }
            } message: { pending in
                Text("They were last changed on \(pending.remote.device), \(pending.remote.modified.formatted(date: .abbreviated, time: .shortened)).")
            }
    }

    private func start(_ folder: URL) {
        Task { await store.startSync(in: folder) }
    }

    /// "OneDrive-Personal" to "OneDrive (Personal)".
    private func oneDriveTitle(_ folder: URL) -> String {
        let account = folder.deletingLastPathComponent().lastPathComponent
            .replacingOccurrences(of: "OneDrive", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return account.isEmpty ? "OneDrive" : "OneDrive (\(account))"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Sync Here"
        panel.message = "Choose a folder that syncs between your Macs."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(url)
    }
}

// MARK: Clipboard

private struct ClipboardPage: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        GlassCard {
            SettingRow(title: "Optimize what you copy") {
                Toggle("Optimize what you copy", isOn: $store.settings.clipboardEnabled).labelsHidden()
            }
        }
        CardFooter("Copied media is replaced with a smaller copy on the clipboard. Squish skips anything it wrote itself.")
        GroupGap()
        CardHeader(title: "Types")
        GlassCard {
            ForEach(Array(FileKind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { CardDivider() }
                SettingRow(title: kind.title) {
                    Toggle(kind.title, isOn: Binding(
                        get: { store.settings.clipboardKinds.contains(kind) },
                        set: { if $0 { store.settings.clipboardKinds.insert(kind) } else { store.settings.clipboardKinds.remove(kind) } }
                    ))
                    .labelsHidden()
                }
            }
        }
        .disabled(!store.settings.clipboardEnabled)
        .opacity(store.settings.clipboardEnabled ? 1 : 0.55)
    }
}

extension FileKind {
    var title: String {
        switch self {
        case .image: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        }
    }

    var color: Color {
        switch self {
        case .image: Tokyo.blue
        case .video: Tokyo.purple
        case .audio: Tokyo.green
        case .pdf: Tokyo.orange
        }
    }
}

// MARK: Folders

private struct FoldersPage: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        GlassCard {
            SettingRow(title: "Optimize new files in watched folders") {
                Toggle("Optimize new files", isOn: $store.settings.foldersEnabled).labelsHidden()
            }
        }
        CardFooter("Only files added or changed after Squish starts are touched. Originals are kept in the backup folder.")
        GroupGap()
        CardHeader(title: "Watched folders")
        GlassCard {
            ForEach($store.settings.folders) { $folder in
                if folder.id != store.settings.folders.first?.id { CardDivider() }
                FolderRow(folder: $folder) {
                    store.settings.folders.removeAll { $0.id == folder.id }
                }
            }
            if !store.settings.folders.isEmpty { CardDivider() }
            HStack {
                GlassButton(title: "Add Folder…", systemImage: "plus", action: addFolder)
                Spacer()
            }
            .padding(12)
        }
        .disabled(!store.settings.foldersEnabled)
        .opacity(store.settings.foldersEnabled ? 1 : 0.55)
    }

    private func addFolder() {
        let existing = Set(store.settings.folders.map(\.url.standardizedFileURL))
        store.settings.folders += chooseFolders(prompt: "Watch")
            .filter { !existing.contains($0.standardizedFileURL) }
            .map(WatchedFolder.init(url:))
    }
}

private struct FolderRow: View {
    @Binding var folder: WatchedFolder
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FolderHeader(path: folder.path, url: folder.url, enabled: $folder.enabled, remove: remove)
            HStack(spacing: 6) {
                ForEach(FileKind.allCases, id: \.self) { kind in
                    Chip(title: kind.title, isOn: Binding(
                        get: { folder.kinds.contains(kind) },
                        set: { if $0 { folder.kinds.insert(kind) } else { folder.kinds.remove(kind) } }
                    ), color: kind.color)
                }
                Spacer()
                Chip(title: "Subfolders", isOn: $folder.recursive, color: Tokyo.teal)
            }
            .padding(.leading, 34)
            .disabled(!folder.enabled)
            .opacity(folder.enabled ? 1 : 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Enable switch, folder name and path, remove button. Shared by watched folders and SVG folders.
private struct FolderHeader<Extra: View>: View {
    let path: String
    let url: URL
    @Binding var enabled: Bool
    let remove: () -> Void
    @ViewBuilder var extra: Extra

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: url.path)
        HStack(spacing: 10) {
            Image(systemName: exists ? "folder.fill" : "questionmark.folder.fill")
                .font(.system(size: 18))
                .foregroundStyle(exists ? Tokyo.yellow : Tokyo.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                    .foregroundStyle(Tokyo.foreground)
                Text(exists ? path : "\(path) · not found on this Mac")
                    .font(.caption)
                    .foregroundStyle(exists ? Tokyo.muted : Tokyo.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(url.path)
            Spacer(minLength: 8)
            extra
            Toggle("Enabled", isOn: $enabled).labelsHidden().controlSize(.small)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Tokyo.muted)
            }
            .buttonStyle(.plain)
            .help("Stop watching this folder")
            .accessibilityLabel("Remove \(path)")
        }
    }
}

extension FolderHeader where Extra == EmptyView {
    init(path: String, url: URL, enabled: Binding<Bool>, remove: @escaping () -> Void) {
        self.init(path: path, url: url, enabled: enabled, remove: remove) { EmptyView() }
    }
}

@MainActor
private func chooseFolders(prompt: String) -> [URL] {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = true
    panel.prompt = prompt
    guard panel.runModal() == .OK else { return [] }
    return panel.urls
}

// MARK: Formats

private struct FormatsPage: View {
    @Environment(SettingsStore.self) private var store

    private static let images: [(String, WritableKeyPath<FormatSettings, FormatOptions>)] = [
        ("PNG", \.png), ("JPEG", \.jpeg), ("GIF", \.gif), ("WebP", \.webp), ("HEIC", \.heic), ("PDF", \.pdf),
    ]

    var body: some View {
        @Bindable var store = store
        CardHeader(title: "Images and PDF")
        GlassCard {
            ForEach(Array(Self.images.enumerated()), id: \.element.0) { index, format in
                if index > 0 { CardDivider() }
                FormatRow(name: format.0, options: $store.settings.formats[dynamicMember: format.1])
            }
        }
        CardFooter("Lossless keeps every pixel and only removes metadata and wasted bytes. Lossy trades quality for size; 80 is a good start, 85–90 for PNG screenshots with text. For PDF it recompresses the images inside.")
        GroupGap()
        CardHeader(title: "Video and audio")
        GlassCard {
            QualityRow(name: "Video", quality: $store.settings.formats.video.quality, note: nil)
            CardDivider()
            QualityRow(name: "Audio", quality: $store.settings.formats.audio.quality,
                       note: "\(AudioOptimizer.bitrate(quality: store.settings.formats.audio.quality)) kbps")
        }
        CardFooter("Video is re-encoded as HEVC and AAC audio with the Mac's hardware encoder, which needs Apple silicon. MP3 files only lose their tags. A result is kept only if it is smaller.")
    }
}

/// Mode and quality on one line, so the page keeps its height whichever mode is picked.
private struct FormatRow: View {
    let name: String
    @Binding var options: FormatOptions

    var body: some View {
        HStack(spacing: 14) {
            Text(name).foregroundStyle(Tokyo.foreground).frame(width: 52, alignment: .leading)
            GlassSegmented(selection: $options.lossy, options: [(false, "Lossless"), (true, "Lossy")],
                           color: options.lossy ? Tokyo.orange : Tokyo.teal, segmentWidth: 76)
            if options.lossy {
                QualitySlider(quality: $options.quality)
            } else {
                Text("Metadata and wasted bytes only")
                    .font(.callout)
                    .foregroundStyle(Tokyo.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
    }
}

private struct QualityRow: View {
    let name: String
    @Binding var quality: Int
    let note: String?

    var body: some View {
        HStack(spacing: 14) {
            Text(name).foregroundStyle(Tokyo.foreground).frame(width: 52, alignment: .leading)
            QualitySlider(quality: $quality)
            if let note {
                Text(note).font(.caption).foregroundStyle(Tokyo.muted).monospacedDigit().frame(width: 62, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
    }
}

private struct QualitySlider: View {
    @Binding var quality: Int

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: Binding(get: { Double(quality) }, set: { quality = Int($0) }), in: 10...100, step: 5)
                .controlSize(.small)
            Text("\(quality)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Tokyo.blue)
                .frame(width: 28, alignment: .trailing)
        }
    }
}

// MARK: SVG

private struct SVGPage: View {
    @Environment(SettingsStore.self) private var store
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = store
        CardHeader(title: "Converting by hand")
        GlassCard {
            SettingRow(title: "Default scale", detail: "Preselected when you convert by hand.") {
                GlassSegmented(selection: $store.settings.svgScale,
                               options: SVG.presetScales.map { ($0, $0.scaleTitle) }, color: Tokyo.orange, segmentWidth: 46)
            }
            CardDivider()
            SettingRow(title: "File names") {
                GlassSegmented(selection: $store.settings.svgNaming, options: [
                    (SVGNaming.scaleSuffix, "icon@2x.png"), (SVGNaming.dimensions, "icon-512x512.png"),
                ], color: Tokyo.orange)
            }
        }
        GroupGap()
        CardHeader(title: "Auto-convert folders")
        GlassCard {
            if store.settings.svgFolders.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(Tokyo.orange)
                    Text("Add a folder, and every SVG saved there gets a PNG copy at the sizes you pick.")
                        .foregroundStyle(Tokyo.secondary)
                }
                .padding(16)
            }
            ForEach($store.settings.svgFolders) { $folder in
                if folder.id != store.settings.svgFolders.first?.id { CardDivider() }
                SVGFolderRow(folder: $folder, naming: store.settings.svgNaming) {
                    store.settings.svgFolders.removeAll { $0.id == folder.id }
                } convertExisting: {
                    model.convertExisting(in: folder)
                }
            }
            CardDivider()
            HStack {
                GlassButton(title: "Add Folder…", systemImage: "plus", color: Tokyo.orange, action: addFolder)
                Spacer()
            }
            .padding(12)
        }
        CardFooter("New or changed SVGs get a PNG next to them for each size, named as above, then optimized. The SVG stays, and a PNG you made yourself is never replaced. \"Convert Existing\" does the SVGs already there.")
    }

    private func addFolder() {
        let existing = Set(store.settings.svgFolders.map(\.url.standardizedFileURL))
        store.settings.svgFolders += chooseFolders(prompt: "Auto-Convert")
            .filter { !existing.contains($0.standardizedFileURL) }
            .map { SVGFolder(url: $0, scales: [store.settings.svgScale]) }
    }
}

private struct SVGFolderRow: View {
    @Binding var folder: SVGFolder
    let naming: SVGNaming
    let remove: () -> Void
    let convertExisting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FolderHeader(path: folder.path, url: folder.url, enabled: $folder.enabled, remove: remove) {
                GlassButton(title: "Convert Existing", systemImage: "arrow.triangle.2.circlepath",
                            color: Tokyo.orange, compact: true, action: convertExisting)
                    .disabled(!folder.enabled)
                    .opacity(folder.enabled ? 1 : 0.5)
                    .help("Make PNGs for the SVGs already in this folder")
            }
            HStack(spacing: 6) {
                Text("Sizes").font(.callout).foregroundStyle(Tokyo.muted).padding(.trailing, 2)
                ForEach(SVG.presetScales, id: \.self) { scale in
                    Chip(title: scale.scaleTitle, isOn: Binding(
                        get: { folder.scales.contains(scale) },
                        set: { on in
                            if on { folder.scales.append(scale) }
                            else if folder.scales.count > 1 { folder.scales.removeAll { $0 == scale } }
                        }
                    ), color: Tokyo.orange)
                }
                Text(example).font(.caption).foregroundStyle(Tokyo.muted).lineLimit(1).padding(.leading, 6)
                Spacer(minLength: 8)
                Chip(title: "Subfolders", isOn: $folder.recursive, color: Tokyo.teal)
            }
            .padding(.leading, 34)
            .disabled(!folder.enabled)
            .opacity(folder.enabled ? 1 : 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// "icon.png, icon@2x.png" for the chosen scales.
    private var example: String {
        let svg = URL(filePath: "/icon.svg")
        return folder.scales.map { scale in
            switch naming {
            case .scaleSuffix: SVG.outputName(for: svg, scale: scale, naming: naming, pixels: (0, 0))
            case .dimensions: "icon-\(scale.scaleTitle).png"
            }
        }
        .joined(separator: ", ")
    }
}

extension Double {
    /// 0.5×, 1×, 2×
    var scaleTitle: String {
        "\(formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX"))))×"
    }
}

// MARK: Shortcuts

private struct ShortcutsPage: View {
    @Environment(SettingsStore.self) private var store
    @Environment(AppModel.self) private var model
    @ViewState private var access: FinderSelection.Access?

    var body: some View {
        CardHeader(title: "Selected in Finder")
        GlassCard {
            row(.optimizeSelection, "Optimize selected files", "Smaller copies replace them; originals go to backups.")
            CardDivider()
            row(.convertSelection, "Convert selected SVGs to PNG", "Opens the size picker. Press Return for the default size.")
        }
        GroupGap()
        CardHeader(title: "Anywhere")
        GlassCard {
            row(.chooseFiles, "Choose files to optimize…", nil)
            CardDivider()
            row(.togglePause, "Pause or resume automatic optimization", nil)
        }
        GroupGap()
        CardHeader(title: "Finder access")
        GlassCard {
            SettingRow(title: accessTitle, detail: accessDetail) {
                switch access {
                case .notAsked:
                    GlassButton(title: "Allow…", systemImage: "hand.raised", color: Tokyo.cyan) {
                        Task { access = await FinderSelection.access(ask: true) }
                    }
                case .denied:
                    GlassButton(title: "Open Privacy Settings", systemImage: "gear", color: Tokyo.orange) {
                        FinderSelection.openAutomationSettings()
                    }
                default:
                    EmptyView()
                }
            }
        }
        CardFooter("Shortcuts work in any app. The Finder ones act on what's selected in the frontmost Finder window or on the desktop. Press Delete while recording to clear a shortcut, Escape to cancel.")
            .task { access = await FinderSelection.access(ask: false) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { access = await FinderSelection.access(ask: false) }
            }
    }

    private func row(_ action: ShortcutAction, _ title: String, _ detail: String?) -> some View {
        let failed = model.hotKeys.failed.contains(action)
        return SettingRow(title: title, detail: failed ? "Taken by macOS or another app. Pick a different one." : detail) {
            ShortcutRecorder(shortcut: binding(for: action), isRecording: Binding(
                get: { model.hotKeys.isSuspended },
                set: { model.hotKeys.isSuspended = $0 }
            ))
        }
    }

    /// Setting a shortcut takes it away from any other action that had it.
    private func binding(for action: ShortcutAction) -> Binding<KeyShortcut?> {
        Binding(
            get: { store.settings.shortcuts[action] },
            set: { shortcut in
                var shortcuts = store.settings.shortcuts
                if let shortcut {
                    for (other, existing) in shortcuts.all where other != action && existing.keyCode == shortcut.keyCode
                        && existing.modifiers == shortcut.modifiers {
                        shortcuts[other] = nil
                    }
                }
                shortcuts[action] = shortcut
                store.settings.shortcuts = shortcuts
            }
        )
    }

    private var accessTitle: String {
        switch access {
        case .allowed: "Squish can read the Finder selection"
        case .notAsked: "Finder access not granted yet"
        case .denied: "Finder access is turned off"
        case .unknown, nil: "Finder access"
        }
    }

    private var accessDetail: String {
        switch access {
        case .allowed: "Allowed in Privacy & Security › Automation."
        case .notAsked: "macOS asks the first time you use a Finder shortcut, or allow it now."
        case .denied: "Turn on Finder under Squish in Privacy & Security › Automation."
        case .unknown, nil: "Checked when Finder is running."
        }
    }
}

/// Click to record, then press the keys. Delete clears, Escape cancels.
private struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?
    /// Shared across recorders, so global shortcuts stay off while any of them is listening.
    @Binding var isRecording: Bool
    @ViewState private var listening = false
    @ViewState private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Group {
                    if listening {
                        Text("Type shortcut…").foregroundStyle(Tokyo.cyan)
                    } else if let shortcut {
                        Text(shortcut.displayString)
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .foregroundStyle(Tokyo.foreground)
                    } else {
                        Text("Record Shortcut").foregroundStyle(Tokyo.muted)
                    }
                }
                .font(.callout)
                .frame(minWidth: 118)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(listening ? Tokyo.cyan.opacity(0.14) : Tokyo.backgroundDeep.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(listening ? Tokyo.cyan.opacity(0.7) : Tokyo.hairline, lineWidth: listening ? 1.25 : 0.75))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(shortcut.map { "Shortcut \($0.displayString). Click to change." } ?? "Record shortcut")
            Button {
                shortcut = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Tokyo.muted)
            }
            .buttonStyle(.plain)
            .help("Clear shortcut")
            .opacity(shortcut == nil || listening ? 0 : 1)
            .disabled(shortcut == nil || listening)
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        listening ? stop() : start()
    }

    private func start() {
        guard !isRecording else { return } // another recorder is listening
        listening = true
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete where event.modifierFlags.intersection(KeyShortcut.allowedModifiers).isEmpty,
                 kVK_ForwardDelete where event.modifierFlags.intersection(KeyShortcut.allowedModifiers).isEmpty:
                shortcut = nil
                stop()
            default:
                if let recorded = KeyShortcut(event: event) {
                    shortcut = recorded
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        guard listening else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
        isRecording = false
    }
}

// MARK: Advanced

private struct AdvancedPage: View {
    @Environment(SettingsStore.self) private var store
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = store
        CardHeader(title: "Performance")
        GlassCard {
            SettingRow(title: "Files at once", detail: "Automatic uses half the performance cores.") {
                Picker("Files at once", selection: $store.settings.concurrency) {
                    Text("Automatic (\(Settings.automaticConcurrency))").tag(0)
                    Divider()
                    ForEach(1...ProcessInfo.processInfo.activeProcessorCount, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        GroupGap()
        CardHeader(title: "Backups")
        GlassCard {
            SettingRow(title: "Keep originals for") {
                Stepper(value: $store.settings.backupDays, in: 1...90) {
                    Text("\(store.settings.backupDays) day\(store.settings.backupDays == 1 ? "" : "s")")
                        .monospacedDigit()
                        .foregroundStyle(Tokyo.secondary)
                }
            }
            CardDivider()
            HStack {
                GlassButton(title: "Show Backups in Finder", systemImage: "archivebox") {
                    try? FileManager.default.createDirectory(at: model.backupsFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.backupsFolder)
                }
                Spacer()
            }
            .padding(12)
        }
        GroupGap()
        CardHeader(title: "Logs")
        GlassCard {
            HStack {
                GlassButton(title: "Open Console", systemImage: "terminal") {
                    NSWorkspace.shared.open(URL(filePath: "/System/Applications/Utilities/Console.app"))
                }
                Spacer()
            }
            .padding(12)
        }
        CardFooter("Filter by subsystem \(AppIdentity.bundleID) to see what Squish did.")
            .textSelection(.enabled)
    }
}
