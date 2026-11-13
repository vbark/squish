import Testing
import UniformTypeIdentifiers
@testable import SquishKit

struct ClipboardRulesTests {
    let images: Set<FileKind> = [.image]

    @Test func `own output is never processed again`() {
        let types = [UTType.png.identifier, ClipboardRules.markerType]
        #expect(ClipboardRules.action(for: types, kinds: images) == .ignore)
    }

    @Test func `password manager items are ignored`() {
        let types = [UTType.png.identifier, "org.nspasteboard.ConcealedType"]
        #expect(ClipboardRules.action(for: types, kinds: images) == .ignore)
    }

    @Test func `PNG is preferred over TIFF when both are offered`() {
        let types = [UTType.tiff.identifier, UTType.png.identifier]
        #expect(ClipboardRules.action(for: types, kinds: images) == .image(.png))
    }

    @Test func `TIFF alone is processed`() {
        #expect(ClipboardRules.action(for: [UTType.tiff.identifier], kinds: images) == .image(.tiff))
    }

    @Test func `Finder copies are handled as files, not as the icon image`() {
        let types = [UTType.fileURL.identifier, UTType.tiff.identifier]
        #expect(ClipboardRules.action(for: types, kinds: images) == .files)
    }

    @Test func `nothing happens when images are switched off`() {
        #expect(ClipboardRules.action(for: [UTType.png.identifier], kinds: [.video]) == .ignore)
        #expect(ClipboardRules.action(for: [UTType.utf8PlainText.identifier], kinds: images) == .ignore)
    }
}
