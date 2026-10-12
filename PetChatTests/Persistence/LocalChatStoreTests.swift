import SwiftData
import XCTest
@testable import PetChat

final class LocalChatStoreTests: XCTestCase {
    func testRestoresThreadAfterStoreRecreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("chats.store"))
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: configuration)
        var thread = ChatThread(providerID: .ollama, modelID: "vision", messages: [
            ChatMessage(role: .user, text: "What is here?", attachmentIDs: [UUID()]),
            ChatMessage(role: .pet, text: "A cat", status: .stopped)
        ])

        try LocalChatStore(container: container).save(thread)
        thread.messages[1].text = "A small cat"
        try LocalChatStore(container: container).save(thread)

        let reopened = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: configuration)
        XCTAssertEqual(try LocalChatStore(container: reopened).load(), [thread])
    }

    func testDeletesOnlySelectedThreadAndAttachments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = AttachmentStore(root: root)
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = LocalChatStore(container: container, attachments: attachments)
        let first = ChatThread(providerID: .ollama, modelID: "a")
        let second = ChatThread(providerID: .chatGPT, modelID: "b")
        let firstImage = try attachments.save(Data([1]), threadID: first.id)
        let secondImage = try attachments.save(Data([2]), threadID: second.id)
        try store.save(first)
        try store.save(second)

        try store.delete(threadID: first.id)

        XCTAssertEqual(try store.load(), [second])
        XCTAssertThrowsError(try attachments.load(firstImage, threadID: first.id))
        XCTAssertEqual(try attachments.load(secondImage, threadID: second.id), Data([2]))
    }

    func testFailedSaveDoesNotReportSuccess() throws {
        enum Failure: Error { case unavailable }
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = LocalChatStore(container: container, saveContext: { _ in throw Failure.unavailable })

        XCTAssertThrowsError(try store.save(ChatThread(providerID: .ollama, modelID: "a"))) { error in
            XCTAssertTrue(error is Failure)
        }
        XCTAssertTrue(try LocalChatStore(container: container).load().isEmpty)
    }
}
