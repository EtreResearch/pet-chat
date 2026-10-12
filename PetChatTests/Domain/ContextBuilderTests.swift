import XCTest
@testable import PetChat

final class ContextBuilderTests: XCTestCase {
    func testEmptyChatContainsOnlyCurrentQuestionAndItsImages() {
        let imageID = UUID()
        let thread = ChatThread(providerID: .ollama, modelID: "vision")

        let prompt = ContextBuilder.build(thread: thread, currentText: "What is this?", currentAttachmentIDs: [imageID], contextWindowTokens: nil)

        XCTAssertEqual(prompt.map(\.text), ["What is this?"])
        XCTAssertEqual(prompt[0].role, .user)
        XCTAssertEqual(prompt[0].attachmentIDs, [imageID])
    }

    func testRecentWholePairsFitAndOldestPairIsDropped() {
        let thread = ChatThread(providerID: .ollama, modelID: "tiny", messages: [
            ChatMessage(role: .user, text: String(repeating: "a", count: 100)),
            ChatMessage(role: .pet, text: String(repeating: "b", count: 100)),
            ChatMessage(role: .user, text: "recent question"),
            ChatMessage(role: .pet, text: "recent answer")
        ])

        let prompt = ContextBuilder.build(thread: thread, currentText: "now", currentAttachmentIDs: [], contextWindowTokens: 1100)

        XCTAssertEqual(prompt.map(\.text), ["recent question", "recent answer", "now"])
    }

    func testRetainedHistoryNeverCarriesOldImages() {
        let oldImage = UUID()
        let newImage = UUID()
        let thread = ChatThread(providerID: .ollama, modelID: "vision", messages: [
            ChatMessage(role: .user, text: "old", attachmentIDs: [oldImage]),
            ChatMessage(role: .pet, text: "reply")
        ])

        let prompt = ContextBuilder.build(thread: thread, currentText: "new", currentAttachmentIDs: [newImage], contextWindowTokens: nil)

        XCTAssertEqual(prompt.map(\.attachmentIDs), [[], [], [newImage]])
    }

    func testOversizedCurrentMessageRemainsIntact() {
        let text = String(repeating: "x", count: 40_000)
        let thread = ChatThread(providerID: .chatGPT, modelID: "small")

        let prompt = ContextBuilder.build(thread: thread, currentText: text, currentAttachmentIDs: [], contextWindowTokens: 1024)

        XCTAssertEqual(prompt.count, 1)
        XCTAssertEqual(prompt[0].text, text)
    }

    func testNewestExchangeRemainsWholeEvenWhenBudgetIsTight() {
        let thread = ChatThread(providerID: .ollama, modelID: "tiny", messages: [
            ChatMessage(role: .user, text: "last question"),
            ChatMessage(role: .pet, text: "last answer")
        ])

        let prompt = ContextBuilder.build(thread: thread, currentText: "now", currentAttachmentIDs: [], contextWindowTokens: 1024)

        XCTAssertEqual(prompt.map(\.text), ["last question", "last answer", "now"])
    }

    func testRequestKeepsImageBytesOnlyForCurrentMessage() {
        let oldImage = UUID()
        let currentImage = UUID()
        let request = GenerationRequest(
            id: UUID(), modelID: "vision",
            messages: [
                PromptMessage(role: .user, text: "old", attachmentIDs: [oldImage]),
                PromptMessage(role: .user, text: "now", attachmentIDs: [currentImage])
            ],
            imageData: [oldImage: Data([1]), currentImage: Data([2])]
        )

        XCTAssertEqual(request.imageData, [currentImage: Data([2])])
    }
}
