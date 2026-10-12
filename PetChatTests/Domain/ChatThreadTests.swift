import XCTest
@testable import PetChat

final class ChatThreadTests: XCTestCase {
    func testNewThreadKeepsProviderAndModelWithoutInheritedMessages() {
        let old = ChatThread(providerID: .ollama, modelID: "llama3", messages: [
            ChatMessage(role: .user, text: "private history")
        ])
        let next = ChatThread(providerID: .chatGPT, modelID: "gpt-5")

        XCTAssertEqual(old.providerID, .ollama)
        XCTAssertEqual(old.modelID, "llama3")
        XCTAssertEqual(next.providerID, .chatGPT)
        XCTAssertEqual(next.modelID, "gpt-5")
        XCTAssertTrue(next.messages.isEmpty)
    }

    func testThreadAndMessageRoundTripPreservesBindingAndOrder() throws {
        let imageID = UUID()
        let thread = ChatThread(providerID: .ollama, modelID: "vision", messages: [
            ChatMessage(role: .user, text: "look", attachmentIDs: [imageID]),
            ChatMessage(role: .pet, text: "a cat", status: .stopped)
        ])

        let restored = try JSONDecoder().decode(ChatThread.self, from: JSONEncoder().encode(thread))

        XCTAssertEqual(restored.providerID, .ollama)
        XCTAssertEqual(restored.modelID, "vision")
        XCTAssertEqual(restored.messages.map(\.text), ["look", "a cat"])
        XCTAssertEqual(restored.messages[0].attachmentIDs, [imageID])
        XCTAssertEqual(restored.messages[1].status, .stopped)
    }
}
