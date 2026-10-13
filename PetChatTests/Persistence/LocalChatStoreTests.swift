import SwiftData
import XCTest
@testable import PetChat

final class LocalChatStoreTests: XCTestCase {
    func testAppOwnedDiskStoreRestartsWithoutTouchingUnrelatedDefaultStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("default.store")
        let unrelated = Data("unrelated application data".utf8)
        try unrelated.write(to: sentinel)
        let directory = root.appendingPathComponent("PetChat")
        let thread = ChatThread(providerID: .ollama, modelID: "local")
        try LocalChatStore(directory: directory).save(thread)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Chats.store").path))
        let reopened = try LocalChatStore(directory: directory)
        XCTAssertEqual(try reopened.load(), [thread])
        try reopened.delete(threadID: thread.id)
        XCTAssertTrue(try LocalChatStore(directory: directory).load().isEmpty)
        XCTAssertEqual(try Data(contentsOf: sentinel), unrelated)
    }

    func testRestoresThreadAfterStoreRecreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("chats.store"))
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: configuration)
        let attachments = AttachmentStore(root: directory.appendingPathComponent("Attachments"))
        var thread = ChatThread(providerID: .ollama, modelID: "vision", messages: [
            ChatMessage(role: .user, text: "What is here?", attachmentIDs: [UUID()]),
            ChatMessage(role: .pet, text: "A cat", status: .stopped)
        ])

        try LocalChatStore(container: container, attachments: attachments).save(thread)
        thread.messages[1].text = "A small cat"
        try LocalChatStore(container: container, attachments: attachments).save(thread)

        let reopened = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: configuration)
        XCTAssertEqual(try LocalChatStore(container: reopened, attachments: attachments).load(), [thread])
    }

    func testDeletesOnlySelectedThreadAndAttachments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = AttachmentStore(root: root)
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try LocalChatStore(container: container, attachments: attachments)
        let first = ChatThread(providerID: .ollama, modelID: "a")
        let second = ChatThread(providerID: .chatGPT, modelID: "b")
        let firstImage = try attachments.save(testPNG(1), threadID: first.id)
        let secondImage = try attachments.save(testPNG(2), threadID: second.id)
        try store.save(first)
        try store.save(second)

        try store.delete(threadID: first.id)

        XCTAssertEqual(try store.load(), [second])
        XCTAssertThrowsError(try attachments.load(firstImage, threadID: first.id))
        XCTAssertEqual(try attachments.load(secondImage, threadID: second.id), testPNG(2))
    }

    func testMessageCreatedAtSurvivesSaveAndLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try LocalChatStore(container: container, attachments: AttachmentStore(root: root))
        let date = Date(timeIntervalSinceReferenceDate: 5000)
        let thread = ChatThread(providerID: .ollama, modelID: "a", messages: [
            ChatMessage(role: .user, text: "dated", createdAt: date),
            ChatMessage(role: .pet, text: "undated", createdAt: nil)
        ])

        try store.save(thread)

        let loaded = try store.load().first?.messages
        XCTAssertEqual(loaded?.map(\.createdAt), [date, nil])
    }

    func testFailedSaveDoesNotReportSuccess() throws {
        enum Failure: Error { case unavailable }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = AttachmentStore(root: root)
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try LocalChatStore(container: container, attachments: attachments, saveContext: { _ in throw Failure.unavailable })

        XCTAssertThrowsError(try store.save(ChatThread(providerID: .ollama, modelID: "a"))) { error in
            XCTAssertTrue(error is Failure)
        }
        XCTAssertTrue(try LocalChatStore(container: container, attachments: attachments).load().isEmpty)
    }

    func testFailedAttachmentCleanupIsReportedAndRetriedOnNextStore() throws {
        enum Failure: Swift.Error { case diskUnavailable }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let attachments = AttachmentStore(root: root, removeItem: { _ in throw Failure.diskUnavailable })
        let thread = ChatThread(providerID: .ollama, modelID: "vision")
        let image = try attachments.save(testPNG(7), threadID: thread.id)
        let store = try LocalChatStore(container: container, attachments: attachments)
        try store.save(thread)

        XCTAssertThrowsError(try store.delete(threadID: thread.id)) { XCTAssertTrue($0 is Failure) }
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".pending-deletion/").appendingPathComponent(thread.id.uuidString).path))

        let reopened = try LocalChatStore(container: container, attachments: AttachmentStore(root: root))
        XCTAssertTrue(try reopened.load().isEmpty)
        XCTAssertThrowsError(try AttachmentStore(root: root).load(image, threadID: thread.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".pending-deletion/").appendingPathComponent(thread.id.uuidString).path))
    }

    func testRetryingDeleteCannotReportSuccessWhileCleanupIsPending() throws {
        enum Failure: Swift.Error { case diskUnavailable }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let attachments = AttachmentStore(root: root, removeItem: { _ in throw Failure.diskUnavailable })
        let thread = ChatThread(providerID: .ollama, modelID: "vision")
        _ = try attachments.save(testPNG(7), threadID: thread.id)
        let store = try LocalChatStore(container: container, attachments: attachments)
        try store.save(thread)

        XCTAssertThrowsError(try store.delete(threadID: thread.id))
        XCTAssertThrowsError(try store.delete(threadID: thread.id)) { XCTAssertTrue($0 is Failure) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".pending-deletion/").appendingPathComponent(thread.id.uuidString).path))
    }

    func testDatabaseDeleteFailureRestoresAttachments() throws {
        enum Failure: Swift.Error { case databaseUnavailable }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = AttachmentStore(root: root)
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let thread = ChatThread(providerID: .ollama, modelID: "vision")
        let image = try attachments.save(testPNG(7), threadID: thread.id)
        try LocalChatStore(container: container, attachments: attachments).save(thread)
        let failing = try LocalChatStore(container: container, attachments: attachments, saveContext: { _ in throw Failure.databaseUnavailable })

        XCTAssertThrowsError(try failing.delete(threadID: thread.id)) { XCTAssertTrue($0 is Failure) }
        XCTAssertEqual(try LocalChatStore(container: container, attachments: attachments).load(), [thread])
        XCTAssertEqual(try attachments.load(image, threadID: thread.id), testPNG(7))
    }
}
