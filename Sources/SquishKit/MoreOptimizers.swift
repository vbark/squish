import Foundation
import ImageIO
import UniformTypeIdentifiers

/// gifsicle. Keeps the loop count; drops comments and frame names.
public struct GIFOptimizer: Optimizer {
    public let types: [UTType] = [.gif]

    public init() {}

    public func options(in formats: FormatSettings) -> FormatOptions { formats.gif }

    public func optimize(_ input: URL, to output: URL, options: FormatOptions, tools: ToolLocator) async throws {
        var arguments = ["-O3", "--no-comments", "--no-names"]
        if options.lossy {
            arguments.append("--lossy=\(max(1, (100 - options.quality) * 2))")
        }
        try await ToolRunner.run(tools.url(for: "gifsicle"), arguments + ["-o", output.path, input.path])
    }
}

/// cwebp / webpmux. Lossless mode never re-encodes lossy WebP; it only strips metadata.
public struct WebPOptimizer: Optimizer {
    public let types: [UTType] = [.webP]

    public init() {}

    public func options(in formats: FormatSettings) -> FormatOptions { formats.webp }

    public func optimize(_ input: URL, to output: URL, options: FormatOptions, tools: ToolLocator) async throws {
        let kind = try Self.kind(of: input)
        if kind == .animated || (kind == .lossy && !options.lossy) {
            try await stripMetadata(input, to: output, tools: tools)
        } else if options.lossy {
            try await ToolRunner.run(tools.url(for: "cwebp"), [
                "-quiet", "-q", "\(options.quality)", "-m", "6", "-metadata", "icc", "-o", output.path, input.path,
            ])
        } else {
            try await ToolRunner.run(tools.url(for: "cwebp"), [
                "-quiet", "-lossless", "-exact", "-z", "9", "-metadata", "icc", "-o", output.path, input.path,
            ])
        }
    }

    /// webpmux fails when the chunk is absent, so strip EXIF and XMP one at a time and tolerate that.
    private func stripMetadata(_ input: URL, to output: URL, tools: ToolLocator) async throws {
        let webpmux = try tools.url(for: "webpmux")
        try FileManager.default.copyItem(at: input, to: output)
        for chunk in ["exif", "xmp"] {
            try? await ToolRunner.run(webpmux, ["-strip", chunk, output.path, "-o", output.path])
        }
    }

    enum Kind { case lossy, lossless, animated }

    /// Reads the RIFF chunk names: VP8L is lossless, ANIM is animated, VP8 is lossy.
    static func kind(of url: URL) throws -> Kind {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 64 * 1024) ?? Data()
        if header.range(of: Data("ANIM".utf8)) != nil { return .animated }
        if header.range(of: Data("VP8L".utf8)) != nil { return .lossless }
        return .lossy
    }
}

/// HEIC and TIFF through ImageIO.
/// TIFF: re-encoded with LZW (lossless). HEIC lossless: GPS and XMP dropped, pixels copied untouched.
/// HEIC lossy: re-encoded at the chosen quality.
public struct ImageIOOptimizer: Optimizer {
    public let types: [UTType] = [.heic, .heif, .tiff]

    public init() {}

    public func options(in formats: FormatSettings) -> FormatOptions { formats.heic }

    public func optimize(_ input: URL, to output: URL, options: FormatOptions, tools: ToolLocator) async throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let type = CGImageSourceGetType(source)
        else { throw SquishError.io("Couldn't read \(input.lastPathComponent).") }
        let count = CGImageSourceGetCount(source)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, count, nil)
        else { throw SquishError.io("Couldn't write \(input.lastPathComponent).") }

        let isTIFF = UTType(type as String)?.conforms(to: .tiff) == true
        if !isTIFF && !options.lossy {
            let copyOptions = [kCGImageMetadataShouldExcludeGPS: true, kCGImageMetadataShouldExcludeXMP: true] as CFDictionary
            guard CGImageDestinationCopyImageSource(destination, source, copyOptions, nil)
            else { throw SquishError.io("Couldn't copy \(input.lastPathComponent).") }
            return
        }
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let original = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            var properties: [CFString: Any] = [:]
            if let orientation = original[kCGImagePropertyOrientation] { properties[kCGImagePropertyOrientation] = orientation }
            if isTIFF {
                properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] // LZW
            } else {
                properties[kCGImageDestinationLossyCompressionQuality] = Double(options.quality) / 100
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination)
        else { throw SquishError.io("Couldn't encode \(input.lastPathComponent).") }
    }
}
