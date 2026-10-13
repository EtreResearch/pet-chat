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

    func testCombiningMarksCannotMakeOldHistoryAppearCheap() {
        let longUnicode = "a" + String(repeating: "\u{0301}", count: 12_000)
        let thread = ChatThread(providerID: .ollama, modelID: "vision", messages: [
            ChatMessage(role: .user, text: longUnicode),
            ChatMessage(role: .pet, text: "old answer"),
            ChatMessage(role: .user, text: "recent question"),
            ChatMessage(role: .pet, text: "recent answer")
        ])

        let prompt = ContextBuilder.build(thread: thread, currentText: "now", currentAttachmentIDs: [], contextWindowTokens: nil)

        XCTAssertEqual(prompt.map(\.text), ["recent question", "recent answer", "now"])
    }

    func testReportsWhichVisibleMessagesAreOutsideCurrentContext() {
        let oldUser = ChatMessage(role: .user, text: String(repeating: "a", count: 100))
        let oldPet = ChatMessage(role: .pet, text: String(repeating: "b", count: 100))
        let recentUser = ChatMessage(role: .user, text: "recent question")
        let recentPet = ChatMessage(role: .pet, text: "recent answer")
        let thread = ChatThread(providerID: .ollama, modelID: "tiny",
                                messages: [oldUser, oldPet, recentUser, recentPet])

        let included = ContextBuilder.includedHistoryIDs(thread: thread, currentText: "now", contextWindowTokens: 1100)

        XCTAssertEqual(included, [recentUser.id, recentPet.id])
        XCTAssertFalse(included.contains(oldUser.id))
        XCTAssertFalse(included.contains(oldPet.id))
    }
}
