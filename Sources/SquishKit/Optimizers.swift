import Foundation
import ImageIO
import UniformTypeIdentifiers

/// oxipng (lossless), optionally after pngquant (lossy).
public struct PNGOptimizer: Optimizer {
    public let types: [UTType] = [.png]

    public init() {}

    public func options(in formats: FormatSettings) -> FormatOptions { formats.png }

    public func optimize(_ input: URL, to output: URL, options: FormatOptions, tools: ToolLocator) async throws {
        var source = input
        if options.lossy {
            do {
                let quality = "\(max(0, options.quality - 15))-\(options.quality)"
                try await ToolRunner.run(tools.url(for: "pngquant"), [
                    "--quality", quality, "--skip-if-larger", "--strip", "--force",
                    "--output", output.path, "--", input.path,
                ])
                source = output
            } catch SquishError.toolFailed(_, let status, _) where status == 98 || status == 99 {
                // 98: result was larger, 99: quality floor unreachable. Fall through to lossless.
            }
        }
        // --strip safe keeps chunks that affect rendering (iCCP, sRGB, gAMA) and drops text and EXIF.
        // --zc 10 instead of the default 11: about 40% faster on screenshots (1.8 s to 1.05 s for 2880x1800)
        // for files about 1.5% larger.
        try await ToolRunner.run(tools.url(for: "oxipng"), [
            "--opt", "2", "--zc", "10", "--strip", "safe", "--quiet", "--out", output.path, source.path,
        ])
    }
}

/// mozjpeg: jpegtran (lossless) or cjpeg (lossy). Keeps the ICC profile and EXIF orientation, drops the rest.
public struct JPEGOptimizer: Optimizer {
    public let types: [UTType] = [.jpeg]

    public init() {}

    public func options(in formats: FormatSettings) -> FormatOptions { formats.jpeg }

    public func optimize(_ input: URL, to output: URL, options: FormatOptions, tools: ToolLocator) async throws {
        let orientation = ImageMetadata.orientation(of: input)
        if options.lossy {
            try await ToolRunner.run(tools.url(for: "cjpeg"), [
                "-quality", "\(options.quality)", "-optimize", "-progressive", "-outfile", output.path, input.path,
            ])
        } else {
            try await ToolRunner.run(tools.url(for: "jpegtran"), [
                "-copy", "icc", "-optimize", "-progressive", "-outfile", output.path, input.path,
            ])
        }
        // Stripping EXIF would otherwise rotate portrait photos sideways.
        if let orientation, orientation != 1 {
            try ImageMetadata.setOrientation(orientation, of: output)
        }
    }
}

enum ImageMetadata {
    static func orientation(of url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties[kCGImagePropertyOrientation] as? Int
    }

    /// Writes only the orientation tag. CGImageDestinationCopyImageSource does not re-encode pixels.
    static func setOrientation(_ orientation: Int, of url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source)
        else { throw SquishError.io("Couldn't read \(url.lastPathComponent).") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil)
        else { throw SquishError.io("Couldn't write \(url.lastPathComponent).") }
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueMatchingImageProperty(
            metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber
        )
        let options = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
        ] as CFDictionary
        guard CGImageDestinationCopyImageSource(destination, source, options, nil)
        else { throw SquishError.io("Couldn't keep the orientation of \(url.lastPathComponent).") }
        try (data as Data).write(to: url, options: .atomic)
    }
}
