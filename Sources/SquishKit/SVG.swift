import CoreGraphics
import Foundation

/// SVG to PNG with the bundled resvg. Sizes follow resvg's rules: width/height in CSS units at 96 dpi,
/// falling back to the viewBox, then to 100x100.
public enum SVG {
    public static let presetScales: [Double] = [0.5, 1, 2, 3]

    /// Size in CSS pixels at 1x.
    public static func intrinsicSize(of url: URL) throws -> CGSize {
        let reader = RootReader()
        let parser = try XMLParser(data: Data(contentsOf: url))
        parser.delegate = reader
        parser.parse()
        guard let attributes = reader.attributes else {
            throw SquishError.io("\(url.lastPathComponent) is not a valid SVG file.")
        }
        let viewBox = attributes["viewBox"].flatMap(parseViewBox)
        let width = length(attributes["width"], relativeTo: viewBox.map { Double($0.width) })
        let height = length(attributes["height"], relativeTo: viewBox.map { Double($0.height) })
        switch (width, height, viewBox) {
        case let (w?, h?, _):
            return CGSize(width: w, height: h)
        case let (w?, nil, box?) where box.width > 0:
            return CGSize(width: w, height: w * box.height / box.width)
        case let (nil, h?, box?) where box.height > 0:
            return CGSize(width: h * box.width / box.height, height: h)
        case let (nil, nil, box?):
            return box.size
        default:
            return CGSize(width: width ?? 100, height: height ?? 100)
        }
    }

    public static func pixelSize(_ size: CGSize, scale: Double) -> (width: Int, height: Int) {
        (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    /// `icon.png` / `icon@2x.png`, or `icon-512x512.png`. Never the SVG itself.
    public static func outputName(for svg: URL, scale: Double, naming: SVGNaming, pixels: (width: Int, height: Int)) -> String {
        let base = svg.deletingPathExtension().lastPathComponent
        switch naming {
        case .scaleSuffix:
            return scale == 1 ? "\(base).png" : "\(base)@\(scale.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX"))))x.png"
        case .dimensions:
            return "\(base)-\(pixels.width)x\(pixels.height).png"
        }
    }

    /// Where to write: next to the SVG. An existing PNG Squish made is replaced; anything else gets a numbered name.
    public static func outputURL(for svg: URL, name: String) -> URL {
        let folder = svg.deletingLastPathComponent()
        var candidate = folder.appending(path: name)
        let stem = (name as NSString).deletingPathExtension
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path), !SelfWriteGuard.isMarked(candidate) {
            candidate = folder.appending(path: "\(stem) \(number).png")
            number += 1
        }
        return candidate
    }

    /// Renders `svg` and returns the PNG's URL. The PNG is marked as Squish output.
    public static func render(_ svg: URL, scale: Double, naming: SVGNaming, tools: ToolLocator) async throws -> URL {
        let pixels = pixelSize(try intrinsicSize(of: svg), scale: scale)
        let output = outputURL(for: svg, name: outputName(for: svg, scale: scale, naming: naming, pixels: pixels))
        // Render beside the target, then move into place, so a watched folder never sees a half-written PNG.
        let temp = output.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await ToolRunner.run(tools.url(for: "resvg"), [
            "-w", "\(pixels.width)", "-h", "\(pixels.height)", svg.path, temp.path,
        ])
        SelfWriteGuard.mark(temp)
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: output)
        }
        return output
    }

    static func length(_ value: String?, relativeTo reference: Double?) -> Double? {
        guard var text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasSuffix("%") {
            guard let reference, let percent = Double(text.dropLast()) else { return nil }
            return reference * percent / 100
        }
        let units: [(String, Double)] = [
            ("px", 1), ("pt", 4.0 / 3), ("pc", 16), ("mm", 96 / 25.4), ("cm", 96 / 2.54), ("in", 96), ("em", 16), ("ex", 8),
        ]
        var factor = 1.0
        for (unit, multiplier) in units where text.hasSuffix(unit) {
            text.removeLast(unit.count)
            factor = multiplier
            break
        }
        return Double(text.trimmingCharacters(in: .whitespaces)).map { $0 * factor }
    }

    static func parseViewBox(_ value: String) -> CGRect? {
        let numbers = value.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    private final class RootReader: NSObject, XMLParserDelegate {
        var attributes: [String: String]?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if name == "svg" || name.hasSuffix(":svg") { self.attributes = attributes }
            parser.abortParsing() // only the root element matters
        }
    }
}
