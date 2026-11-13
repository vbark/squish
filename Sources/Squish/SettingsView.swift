import AppKit
import ServiceManagement
import SquishKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            ClipboardTab().tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            FoldersTab().tabItem { Label("Folders", systemImage: "folder") }
            FormatsTab().tabItem { Label("Formats", systemImage: "photo.stack") }
            SVGTab().tabItem { Label("SVG", systemImage: "square.on.circle") }
            AdvancedTab().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 420)
    }
}

// MARK: General

private struct GeneralTab: View {
    @Environment(SettingsStore.self) private var store
    @ViewState private var loginError: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
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
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Results") {
                Picker("Show results as", selection: $store.settings.toastStyle) {
                    Text("Floating card").tag(ToastStyle.panel)
                    Text("Notification").tag(ToastStyle.notification)
                }
                Toggle("Play a sound when a file gets smaller", isOn: $store.settings.sounds)
            }
            SyncSection()
        }
    }
}

private struct SyncSection: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        Section {
            if let folder = store.syncFolder {
                LabeledContent("Syncing to") {
                    Text((folder.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(folder.path)
                }
                if let lastSynced = store.lastSynced {
                    LabeledContent("Last synced", value: lastSynced.formatted(date: .omitted, time: .shortened))
                }
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([SettingsFile(folder: folder).url])
                    }
                    Spacer()
                    Button("Stop Syncing", role: .destructive) { store.stopSync() }
                }
            } else {
                HStack {
                    if let iCloud = SettingsStore.iCloudFolder {
                        Button("Use iCloud Drive") { start(iCloud) }
                    }
                    ForEach(SettingsStore.oneDriveFolders, id: \.self) { folder in
                        Button(oneDriveTitle(folder)) { start(folder) }
                    }
                    Button("Choose Folder…", action: chooseFolder)
                }
            }
            if let error = store.syncError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Sync settings")
        } footer: {
            Text("Keeps a settings.json file in the folder. Other Macs using the same folder pick up changes within 15 seconds. Pause, open at login and the sync folder stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
        return account.isEmpty ? "Use OneDrive" : "Use OneDrive (\(account))"
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

private struct ClipboardTab: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Optimize what you copy", isOn: $store.settings.clipboardEnabled)
            } footer: {
                Text("Copied media is replaced with a smaller copy on the clipboard. Squish skips anything it wrote itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Types") {
                KindToggles(kinds: $store.settings.clipboardKinds)
            }
            .disabled(!store.settings.clipboardEnabled)
        }
    }
}

private struct KindToggles: View {
    @Binding var kinds: Set<FileKind>

    var body: some View {
        ForEach(FileKind.allCases, id: \.self) { kind in
            Toggle(kind.title, isOn: Binding(
                get: { kinds.contains(kind) },
                set: { if $0 { kinds.insert(kind) } else { kinds.remove(kind) } }
            ))
        }
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
}

// MARK: Folders

private struct FoldersTab: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Optimize new files in watched folders", isOn: $store.settings.foldersEnabled)
            } footer: {
                Text("Only files added or changed after Squish starts are touched. Originals are kept in the backup folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach($store.settings.folders) { $folder in
                    FolderRow(folder: $folder) {
                        store.settings.folders.removeAll { $0.id == folder.id }
                    }
                }
                Button("Add Folder…", action: addFolder)
            } header: {
                Text("Watched folders")
            }
            .disabled(!store.settings.foldersEnabled)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        guard panel.runModal() == .OK else { return }
        let existing = Set(store.settings.folders.map(\.url.standardizedFileURL))
        store.settings.folders += panel.urls
            .filter { !existing.contains($0.standardizedFileURL) }
            .map(WatchedFolder.init(url:))
    }
}

private struct FolderRow: View {
    @Binding var folder: WatchedFolder
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: $folder.enabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.path).lineLimit(1).truncationMode(.middle)
                        if !FileManager.default.fileExists(atPath: folder.url.path) {
                            Text("Not found on this Mac").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                Spacer()
                Button("Remove", role: .destructive, action: remove)
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
            }
            HStack(spacing: 14) {
                ForEach(FileKind.allCases, id: \.self) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { folder.kinds.contains(kind) },
                        set: { if $0 { folder.kinds.insert(kind) } else { folder.kinds.remove(kind) } }
                    ))
                }
                Spacer()
                Toggle("Subfolders", isOn: $folder.recursive)
            }
            .toggleStyle(.checkbox)
            .font(.callout)
            .padding(.leading, 20)
            .disabled(!folder.enabled)
        }
        .padding(.vertical, 2)
    }
}

// MARK: Formats

private struct FormatsTab: View {
    @Environment(SettingsStore.self) private var store

    private static let formats: [(String, WritableKeyPath<FormatSettings, FormatOptions>)] = [
        ("PNG", \.png), ("JPEG", \.jpeg), ("GIF", \.gif), ("WebP", \.webp), ("HEIC", \.heic),
        ("Video", \.video), ("Audio", \.audio), ("PDF", \.pdf),
    ]

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                ForEach(Self.formats, id: \.0) { name, keyPath in
                    FormatRow(name: name, options: $store.settings.formats[dynamicMember: keyPath])
                }
            } footer: {
                Text("Lossless keeps every pixel and only removes metadata and wasted bytes. Lossy trades quality for size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct FormatRow: View {
    let name: String
    @Binding var options: FormatOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(name, selection: $options.lossy) {
                Text("Lossless").tag(false)
                Text("Lossy").tag(true)
            }
            .pickerStyle(.segmented)
            if options.lossy {
                LabeledContent("Quality") {
                    HStack {
                        Slider(
                            value: Binding(get: { Double(options.quality) }, set: { options.quality = Int($0) }),
                            in: 10...100, step: 5
                        )
                        Text("\(options.quality)").monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                }
                .font(.callout)
            }
        }
    }
}

// MARK: SVG

private struct SVGTab: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Picker("Default scale", selection: $store.settings.svgScale) {
                ForEach([0.5, 1, 2, 3], id: \.self) { scale in
                    Text("\(scale.formatted())×").tag(scale)
                }
            }
            .pickerStyle(.segmented)
            Picker("File names", selection: $store.settings.svgNaming) {
                Text("icon.png, icon@2x.png").tag(SVGNaming.scaleSuffix)
                Text("icon-512x512.png").tag(SVGNaming.dimensions)
            }
            .pickerStyle(.radioGroup)
        }
    }
}

// MARK: Advanced

private struct AdvancedTab: View {
    @Environment(SettingsStore.self) private var store
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker("Files at once", selection: $store.settings.concurrency) {
                    Text("Automatic (\(Settings.automaticConcurrency))").tag(0)
                    Divider()
                    ForEach(1...ProcessInfo.processInfo.activeProcessorCount, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Section("Backups") {
                Stepper(
                    "Keep originals for \(store.settings.backupDays) day\(store.settings.backupDays == 1 ? "" : "s")",
                    value: $store.settings.backupDays, in: 1...90
                )
                Button("Show Backups in Finder") {
                    try? FileManager.default.createDirectory(at: model.backupsFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.backupsFolder)
                }
            }
            Section {
                Button("Open Console") {
                    NSWorkspace.shared.open(URL(filePath: "/System/Applications/Utilities/Console.app"))
                }
            } header: {
                Text("Logs")
            } footer: {
                Text("Filter by subsystem \(AppIdentity.bundleID) to see what Squish did.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}
