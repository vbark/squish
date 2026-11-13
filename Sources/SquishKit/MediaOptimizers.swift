import Foundation
import UniformTypeIdentifiers

/// ffmpeg with Apple's hardware encoders: HEVC video, AAC audio, same container. Always lossy.
public struct VideoOptimizer: Optimizer {
    public let types: [UTType] = [.mpeg4Movie, .quickTimeMovie, UTType("com.apple.m4v-video") ?? .mpeg4Movie]

    public init() {}

    public func options(in formats: FormatSettings) -> FormatOptions { formats.video }

    public func optimize(_ input: URL, to output: URL, options: FormatOptions, tools: ToolLocator) async throws {
        // shortcut: -q:v needs Apple silicon; Intel Macs fail here and the file is left untouched.
        try await ToolRunner.run(tools.url(for: "ffmpeg"), FFmpeg.common(input) + [
            "-map", "0:v:0", "-map", "0:a:0?",
            "-c:v", "hevc_videotoolbox", "-q:v", "\(options.quality)", "-tag:v", "hvc1",
            "-c:a", "aac_at", "-b:a", "160k",
            "-map_metadata", "-1", "-movflags", "+faststart", output.path,
        ])
    }
}

/// AAC (.m4a) is re-encoded at a bitrate from the quality slider. MP3 only loses its tags and cover art,
/// because re-encoding MP3 would need an MP3 encoder and always costs quality.
public struct AudioOptimizer: Optimizer {
    public let types: [UTType] = [.mpeg4Audio, .mp3]

    public init() {}

    public func options(in formats: FormatSettings) -> FormatOptions { formats.audio }

    public func optimize(_ input: URL, to output: URL, options: FormatOptions, tools: ToolLocator) async throws {
        let type = UTType(filenameExtension: input.pathExtension)
        let codec: [String] = if type?.conforms(to: .mp3) == true {
            ["-c:a", "copy", "-write_id3v1", "0", "-id3v2_version", "0"]
        } else {
            ["-c:a", "aac_at", "-b:a", "\(Self.bitrate(quality: options.quality))k"]
        }
        try await ToolRunner.run(tools.url(for: "ffmpeg"), FFmpeg.common(input) + [
            "-vn", "-map", "0:a:0",
        ] + codec + ["-map_metadata", "-1", output.path])
    }

    /// 64 kbps at the bottom of the slider, 256 kbps at the top, in steps of 32.
    static func bitrate(quality: Int) -> Int {
        max(64, min(256, Int((Double(quality) * 2.56 / 32).rounded()) * 32))
    }
}

enum FFmpeg {
    static func common(_ input: URL) -> [String] {
        ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", input.path]
    }
}

/// qpdf: object streams, maximum Flate compression, document metadata removed.
/// Lossy additionally recompresses images as JPEG at the chosen quality.
public struct PDFOptimizer: Optimizer {
    public let types: [UTType] = [.pdf]

    public init() {}

    public func options(in formats: FormatSettings) -> FormatOptions { formats.pdf }

    public func optimize(_ input: URL, to output: URL, options: FormatOptions, tools: ToolLocator) async throws {
        var arguments = [
            "--object-streams=generate", "--compress-streams=y", "--recompress-flate", "--compression-level=9",
            "--remove-metadata", "--remove-info",
        ]
        if options.lossy {
            arguments += ["--optimize-images", "--jpeg-quality=\(options.quality)"]
        }
        do {
            try await ToolRunner.run(tools.url(for: "qpdf"), arguments + [input.path, output.path])
        } catch SquishError.toolFailed(_, let status, _) where status == 3 {
            // 3: finished with warnings (common in real-world PDFs); the output is complete.
        }
    }
}
