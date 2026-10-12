import SwiftData
import XCTest
@testable import PetChat

@MainActor
final class ChatCoordinatorTests: XCTestCase {
    func testStreamPersistsOrderedDeltasAndCompletion() async throws {
        let fixture = try Fixture()
        fixture.provider.events = [.textDelta("Hello"), .textDelta(" there"), .completed]
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")

        try await fixture.coordinator.send(text: "Hi", attachmentIDs: [], threadID: thread.id)

        let saved = try XCTUnwrap(fixture.store.load().first)
        XCTAssertEqual(saved.messages.map(\.text), ["Hi", "Hello there"])
        XCTAssertEqual(saved.messages.last?.status, .complete)
        XCTAssertTrue(fixture.snapshots.threads.contains { $0.messages.last?.text == "Hello" })
        XCTAssertTrue(fixture.snapshots.threads.contains { $0.messages.last?.text == "Hello there" })
    }

    func testDifferentProviderThreadStartsWithEmptyContext() async throws {
        let fixture = try Fixture()
        fixture.provider.events = [.textDelta("first answer"), .completed]
        let first = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")
        try await fixture.coordinator.send(text: "private first question", attachmentIDs: [], threadID: first.id)
        let second = try fixture.coordinator.newThread(providerID: .chatGPT, modelID: "gpt")
        try await fixture.coordinator.send(text: "second question", attachmentIDs: [], threadID: second.id)

        let request = try XCTUnwrap(fixture.otherProvider.requests.last)
        XCTAssertEqual(request.modelID, "gpt")
        XCTAssertEqual(request.messages.map(\.text), ["second question"])
        XCTAssertTrue(try XCTUnwrap(fixture.store.load().first { $0.id == second.id }).messages.first?.text == "second question")
    }

    func testDeletedThreadCannotBeSentAndDeletesItsAttachments() async throws {
        let fixture = try Fixture()
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "vision")
        let image = try fixture.attachments.save(Data([1, 2]), threadID: thread.id)

        try fixture.coordinator.deleteThread(thread.id)

        do {
            try await fixture.coordinator.send(text: "Hi", attachmentIDs: [image], threadID: thread.id)
            XCTFail("Deleted thread accepted a message")
        } catch {
            XCTAssertTrue(fixture.provider.requests.isEmpty)
        }
        XCTAssertThrowsError(try fixture.attachments.load(image, threadID: thread.id))
    }
}

@MainActor
private final class Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let attachments: AttachmentStore
    let store: LocalChatStore
    let provider = ScriptedProvider(id: .ollama)
    let otherProvider = ScriptedProvider(id: .chatGPT)
    let snapshots = SnapshotBox()
    lazy var coordinator = try! ChatCoordinator(providers: [.ollama: provider, .chatGPT: otherProvider], store: store, attachments: attachments)

    init() throws {
        attachments = AttachmentStore(root: directory)
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let snapshots = snapshots
        store = try LocalChatStore(container: container, attachments: attachments, saveContext: { context in
            try context.save()
            snapshots.threads += try context.fetch(FetchDescriptor<ChatRecord>()).map { try $0.thread() }
        })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor private final class SnapshotBox { var threads: [ChatThread] = [] }

private final class ScriptedProvider: ChatProvider, @unchecked Sendable {
    let providerID: ProviderID
    var events: [GenerationEvent] = [.completed]
    var requests: [GenerationRequest] = []

    init(id: ProviderID) { providerID = id }
    func availableModels() async throws -> [ProviderModel] {
        [ProviderModel(id: providerID == .ollama ? "text" : "gpt", displayName: "Test", supportsImages: true, contextWindowTokens: 4096)]
    }
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
    func cancel(_ requestID: UUID) async {}
}
