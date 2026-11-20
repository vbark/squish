import Foundation
import UniformTypeIdentifiers

/// Broad media categories the user can switch on and off per source.
public enum FileKind: String, Codable, CaseIterable, Sendable {
    case image, video, audio, pdf

    public init?(type: UTType) {
        if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .movie) { self = .video }
        else if type.conforms(to: .audio) { self = .audio }
        else if type.conforms(to: .pdf) { self = .pdf }
        else { return nil }
    }
}

public struct FormatOptions: Codable, Equatable, Sendable {
    public var lossy = false
    /// 1...100. Only used when `lossy` is on.
    public var quality = 80

    public init(lossy: Bool = false, quality: Int = 80) {
        self.lossy = lossy
        self.quality = quality
    }
}

public struct FormatSettings: Codable, Equatable, Sendable {
    public var png = FormatOptions()
    public var jpeg = FormatOptions()
    public var gif = FormatOptions()
    public var webp = FormatOptions()
    public var heic = FormatOptions()
    public var video = FormatOptions(lossy: true, quality: 70)
    public var audio = FormatOptions(lossy: true, quality: 50)
    public var pdf = FormatOptions()

    public init() {}
}

public enum ToastStyle: String, Codable, CaseIterable, Sendable {
    case panel, notification
}

public enum SVGNaming: String, Codable, CaseIterable, Sendable {
    /// icon.png at 1x, icon@2x.png otherwise.
    case scaleSuffix
    /// icon-512x512.png
    case dimensions
}

/// A folder Squish watches. Paths are home-relative (`~/Desktop`) so one settings file works on every Mac.
public protocol WatchedLocation {
    var path: String { get }
    var enabled: Bool { get }
    var recursive: Bool { get }
}

extension WatchedLocation {
    public var url: URL {
        URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    static func homeRelative(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// A folder whose new files are optimized in place.
public struct WatchedFolder: WatchedLocation, Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var path: String
    public var enabled = true
    public var kinds: Set<FileKind> = [.image]
    public var recursive = false

    public init(path: String) {
        self.path = path
    }

    public init(url: URL) {
        self.path = Self.homeRelative(url)
    }

    // Decoded by hand so folders written by older versions still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        kinds = try c.decodeIfPresent(Set<FileKind>.self, forKey: .kinds) ?? [.image]
        recursive = try c.decodeIfPresent(Bool.self, forKey: .recursive) ?? false
    }
}

/// A folder whose new or changed SVGs get a PNG copy next to them, one per scale.
public struct SVGFolder: WatchedLocation, Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var path: String
    public var enabled = true
    /// Sorted, never empty.
    public var scales: [Double] = [1] {
        didSet { scales = Self.normalized(scales) }
    }
    public var recursive = false

    public init(path: String, scales: [Double] = [1]) {
        self.path = path
        self.scales = Self.normalized(scales)
    }

    public init(url: URL, scales: [Double] = [1]) {
        self.init(path: Self.homeRelative(url), scales: scales)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        scales = Self.normalized(try c.decodeIfPresent([Double].self, forKey: .scales) ?? [1])
        recursive = try c.decodeIfPresent(Bool.self, forKey: .recursive) ?? false
    }

    static func normalized(_ scales: [Double]) -> [Double] {
        let valid = Set(scales.filter { $0 > 0 && $0 <= 16 }).sorted()
        return valid.isEmpty ? [1] : valid
    }
}

/// Everything that syncs between Macs. Device-only state (sync folder, pause, launch at login) lives elsewhere.
public struct Settings: Codable, Equatable, Sendable {
    public var clipboardEnabled = true
    public var clipboardKinds: Set<FileKind> = [.image]
    public var foldersEnabled = true
    public var folders = [WatchedFolder(path: "~/Desktop"), WatchedFolder(path: "~/Downloads")]
    public var toastStyle = ToastStyle.panel
    public var sounds = false
    public var formats = FormatSettings()
    public var svgScale = 1.0
    public var svgNaming = SVGNaming.scaleSuffix
    public var svgFolders: [SVGFolder] = []
    /// None by default, so nothing collides with shortcuts from other apps until the user picks one.
    public var shortcuts = ShortcutMap()
    /// 0 means automatic, so Macs with different core counts can share one file.
    public var concurrency = 0
    public var backupDays = 7

    public init() {}

    public var effectiveConcurrency: Int {
        concurrency > 0 ? concurrency : Self.automaticConcurrency
    }

    /// Half the performance cores, at least 1.
    public static let automaticConcurrency: Int = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) != 0 || cores <= 0 {
            cores = Int32(ProcessInfo.processInfo.activeProcessorCount)
        }
        return max(1, Int(cores) / 2)
    }()
}

public enum AppIdentity {
    public static let bundleID = Bundle.main.bundleIdentifier ?? "app.squish.Squish"
}
