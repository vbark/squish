import Foundation

/// What gets written to UserDefaults and to the shared settings.json.
public struct SettingsEnvelope: Codable, Equatable, Sendable {
    public var format = 1
    /// Whole seconds, so the value survives an ISO 8601 round trip unchanged.
    public var modified: Date
    public var device: String
    public var settings: Settings

    public init(modified: Date, device: String, settings: Settings) {
        self.modified = modified
        self.device = device
        self.settings = settings
    }
}

public enum SettingsCodec {
    public static func encode(_ envelope: SettingsEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    /// Keys missing from `data` fall back to defaults, so files from older versions still load.
    public static func decode(_ data: Data) throws -> SettingsEnvelope {
        let defaults = SettingsEnvelope(modified: .distantPast, device: "", settings: Settings())
        let base = try JSONSerialization.jsonObject(with: encode(defaults))
        let file = try JSONSerialization.jsonObject(with: data)
        let merged = try JSONSerialization.data(withJSONObject: merge(base, file))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SettingsEnvelope.self, from: merged)
    }

    private static func merge(_ base: Any, _ override: Any) -> Any {
        guard let base = base as? [String: Any], let override = override as? [String: Any] else { return override }
        return base.merging(override) { merge($0, $1) }
    }
}

/// settings.json inside a user-chosen folder, typically in iCloud Drive or OneDrive.
public struct SettingsFile: Sendable {
    public let url: URL

    public init(folder: URL) {
        url = folder.appending(path: "settings.json")
    }

    /// Blocks while a cloud provider downloads the file. Call off the main actor.
    public func read() throws -> SettingsEnvelope? {
        var result: Result<Data?, any Error> = .success(nil)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil }
        }
        if let coordinationError { throw coordinationError }
        return try result.get().map(SettingsCodec.decode)
    }

    public func write(_ envelope: SettingsEnvelope) throws {
        let data = try SettingsCodec.encode(envelope)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var result: Result<Void, any Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            result = Result { try data.write(to: url, options: .atomic) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Cheap stat, used to poll for changes made on other Macs.
    public var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
