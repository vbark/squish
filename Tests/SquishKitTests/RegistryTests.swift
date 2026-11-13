import Testing
import UniformTypeIdentifiers
@testable import SquishKit

struct RegistryTests {
    let registry = OptimizerRegistry.standard

    @Test func `PNG goes to the PNG optimizer`() {
        #expect(registry.optimizer(for: .png) is PNGOptimizer)
    }

    @Test func `JPEG goes to the JPEG optimizer`() throws {
        #expect(registry.optimizer(for: .jpeg) is JPEGOptimizer)
        let fromExtension = try #require(UTType(filenameExtension: "jpg"))
        #expect(registry.optimizer(for: fromExtension) is JPEGOptimizer)
    }

    @Test(arguments: [UTType.svg, .text, .wav, .avi])
    func `types without an optimizer return nil`(type: UTType) {
        #expect(registry.optimizer(for: type) == nil)
    }

    @Test func `file kinds map from UTType`() {
        #expect(FileKind(type: .png) == .image)
        #expect(FileKind(type: .mpeg4Movie) == .video)
        #expect(FileKind(type: .mp3) == .audio)
        #expect(FileKind(type: .pdf) == .pdf)
        #expect(FileKind(type: .plainText) == nil)
    }
}

struct MoreRegistryTests {
    @Test func `new image formats have optimizers`() {
        let registry = OptimizerRegistry.standard
        #expect(registry.optimizer(for: .gif) is GIFOptimizer)
        #expect(registry.optimizer(for: .webP) is WebPOptimizer)
        #expect(registry.optimizer(for: .heic) is ImageIOOptimizer)
        #expect(registry.optimizer(for: .tiff) is ImageIOOptimizer)
        #expect(registry.optimizer(for: .mpeg4Movie) is VideoOptimizer)
        #expect(registry.optimizer(for: .quickTimeMovie) is VideoOptimizer)
        #expect(registry.optimizer(for: .mp3) is AudioOptimizer)
        #expect(registry.optimizer(for: .mpeg4Audio) is AudioOptimizer)
        #expect(registry.optimizer(for: .pdf) is PDFOptimizer)
    }

    @Test(arguments: zip([1, 50, 70, 100], [64, 128, 192, 256]))
    func `audio bitrate follows the quality slider`(quality: Int, kbps: Int) {
        #expect(AudioOptimizer.bitrate(quality: quality) == kbps)
    }
}
