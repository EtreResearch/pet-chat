import AppKit
import XCTest
@testable import PetChat

final class AttachmentStoreTests: XCTestCase {
    func testInvalidImageIsRejectedWithoutCreatingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(root: root)
        XCTAssertThrowsError(try store.save(Data("not an image".utf8), threadID: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testMissingAttachmentReturnsRecoverableError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AttachmentStore(root: root)

        XCTAssertThrowsError(try store.load(UUID(), threadID: UUID())) { error in
            XCTAssertEqual(error as? AttachmentStore.Error, .missing)
        }
    }
}

func testPNG(_ value: UInt8 = 1) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
    bitmap.bitmapData![0] = value
    bitmap.bitmapData![3] = 255
    return bitmap.representation(using: .png, properties: [:])!
}
