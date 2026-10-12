import XCTest
@testable import PetChat

final class AttachmentStoreTests: XCTestCase {
    func testMissingAttachmentReturnsRecoverableError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AttachmentStore(root: root)

        XCTAssertThrowsError(try store.load(UUID(), threadID: UUID())) { error in
            XCTAssertEqual(error as? AttachmentStore.Error, .missing)
        }
    }
}
