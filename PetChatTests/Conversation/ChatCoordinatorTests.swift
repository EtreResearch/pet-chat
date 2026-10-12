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
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertTrue(request.messages[0].text.hasSuffix("second question"))
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

    func testStopPersistsPartialResponseAndIgnoresLaterChunks() async throws {
        let fixture = try Fixture()
        let started = expectation(description: "provider started")
        fixture.provider.events = [.textDelta("Partial")]
        fixture.provider.holdOpen = true
        fixture.provider.onStream = { started.fulfill() }
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")
        let send = Task { try await fixture.coordinator.send(text: "Hi", attachmentIDs: [], threadID: thread.id) }
        await fulfillment(of: [started], timeout: 2)

        try await fixture.coordinator.stop(threadID: thread.id)
        fixture.provider.continuation?.yield(.textDelta(" ignored"))
        fixture.provider.continuation?.finish()
        try await send.value

        let saved = try XCTUnwrap(fixture.store.load().first)
        XCTAssertEqual(saved.messages.last?.text, "Partial")
        XCTAssertEqual(saved.messages.last?.status, .stopped)
    }

    func testProviderFailureLeavesFailedTurnVisible() async throws {
        let fixture = try Fixture()
        fixture.provider.events = [.textDelta("Partial")]
        fixture.provider.failure = TestFailure.disconnected
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")

        do {
            try await fixture.coordinator.send(text: "Hi", attachmentIDs: [], threadID: thread.id)
            XCTFail("Expected provider failure")
        } catch {
            XCTAssertTrue(error is TestFailure)
        }

        let saved = try XCTUnwrap(fixture.store.load().first)
        XCTAssertEqual(saved.messages.map(\.text), ["Hi", "Partial"])
        XCTAssertEqual(saved.messages.last?.status, .failed)
    }

    func testInterruptedStreamReloadsAsFailedNotComplete() async throws {
        let fixture = try Fixture()
        fixture.provider.events = [.textDelta("unfinished")]
        fixture.provider.failure = TestFailure.disconnected
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")
        try? await fixture.coordinator.send(text: "Hi", attachmentIDs: [], threadID: thread.id)

        let restored = try ChatCoordinator(providers: [.ollama: fixture.provider], store: fixture.store,
                                           attachments: fixture.attachments)
        XCTAssertEqual(restored.threads.first?.messages.last?.status, .failed)
        XCTAssertEqual(restored.threads.first?.messages.last?.text, "unfinished")
    }

    func testAppModelKeepsDraftAndAttachmentAfterProviderError() async throws {
        let fixture = try Fixture()
        fixture.provider.failure = TestFailure.disconnected
        let model = AppModel(coordinator: fixture.coordinator)
        try model.select(providerID: .ollama, modelID: "text")
        let thread = try XCTUnwrap(model.thread)
        let image = try fixture.attachments.save(Data([1]), threadID: thread.id)
        model.draft = "What is this?"
        model.attachmentIDs = [image]

        await model.submit()

        XCTAssertEqual(model.draft, "What is this?")
        XCTAssertEqual(model.attachmentIDs, [image])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try fixture.attachments.load(image, threadID: thread.id), Data([1]))
    }

    func testChangingModelStartsEmptyThread() throws {
        let fixture = try Fixture()
        let model = AppModel(coordinator: fixture.coordinator)
        try model.select(providerID: .ollama, modelID: "text")
        let firstID = try XCTUnwrap(model.thread?.id)
        model.draft = "old question"

        try model.select(providerID: .chatGPT, modelID: "gpt")

        XCTAssertNotEqual(model.thread?.id, firstID)
        XCTAssertEqual(model.thread?.messages, [])
        XCTAssertEqual(model.thread?.providerID, .chatGPT)
        XCTAssertEqual(model.draft, "")
    }

    func testRetryReplacesFailedTurnWithoutSendingItsPartialReplyAsContext() async throws {
        let fixture = try Fixture()
        fixture.provider.events = [.textDelta("broken")]
        fixture.provider.failure = TestFailure.disconnected
        let model = AppModel(coordinator: fixture.coordinator)
        try model.select(providerID: .ollama, modelID: "text")
        model.draft = "Question"
        await model.submit()
        fixture.provider.events = [.textDelta("Working"), .completed]
        fixture.provider.failure = nil

        await model.retry()

        XCTAssertEqual(fixture.provider.requests.last?.messages.count, 1)
        XCTAssertTrue(fixture.provider.requests.last?.messages[0].text.hasSuffix("Question") == true)
        XCTAssertEqual(model.thread?.messages.map(\.text), ["Question", "Working"])
        XCTAssertEqual(model.draft, "")
    }

    func testDeletionDuringModelDiscoveryCannotResurrectThread() async throws {
        let fixture = try Fixture()
        let started = expectation(description: "model discovery started")
        fixture.provider.holdModels = true
        fixture.provider.onModels = { started.fulfill() }
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")
        let send = Task { try await fixture.coordinator.send(text: "Hi", attachmentIDs: [], threadID: thread.id) }
        await fulfillment(of: [started], timeout: 2)

        try fixture.coordinator.deleteThread(thread.id)
        fixture.provider.modelsGate?.resume()
        do { try await send.value; XCTFail("Deleted thread was sent") }
        catch { XCTAssertTrue(fixture.provider.requests.isEmpty) }
        XCTAssertTrue(try fixture.store.load().isEmpty)
    }

    func testStopCancelsProviderAndReportsFailedLocalSave() async throws {
        let fixture = try Fixture()
        let started = expectation(description: "stream started")
        fixture.provider.events = [.textDelta("Partial")]
        fixture.provider.holdOpen = true
        fixture.provider.onStream = { started.fulfill() }
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")
        let send = Task { try await fixture.coordinator.send(text: "Hi", attachmentIDs: [], threadID: thread.id) }
        await fulfillment(of: [started], timeout: 2)
        fixture.snapshots.failNextSave = true

        do { try await fixture.coordinator.stop(threadID: thread.id); XCTFail("Expected save error") }
        catch { XCTAssertTrue(error is TestFailure) }
        XCTAssertTrue(fixture.provider.cancelled)
        try await send.value
        XCTAssertEqual(try fixture.store.load().first?.messages.last?.status, .failed)
    }

    func testAppModelPreservesEditedDraftAndBlocksChatSwitchDuringSend() async throws {
        let fixture = try Fixture()
        let started = expectation(description: "stream started")
        fixture.provider.holdOpen = true
        fixture.provider.onStream = { started.fulfill() }
        let model = AppModel(coordinator: fixture.coordinator)
        try model.select(providerID: .ollama, modelID: "text")
        let firstID = model.thread?.id
        model.draft = "Original"
        let send = Task { await model.submit() }
        await fulfillment(of: [started], timeout: 2)
        model.draft = "Next question"

        XCTAssertThrowsError(try model.select(providerID: .chatGPT, modelID: "gpt"))
        XCTAssertEqual(model.thread?.id, firstID)
        fixture.provider.continuation?.yield(.completed)
        fixture.provider.continuation?.finish()
        await send.value
        XCTAssertEqual(model.draft, "Next question")
    }

    func testOlderModelDiscoveryCannotReplaceNewProviderModels() async throws {
        let fixture = try Fixture()
        let started = expectation(description: "old discovery started")
        fixture.provider.holdModels = true
        fixture.provider.onModels = { started.fulfill() }
        let model = AppModel(coordinator: fixture.coordinator)
        let old = Task { await model.loadModels(for: .ollama) }
        await fulfillment(of: [started], timeout: 2)

        await model.loadModels(for: .chatGPT)
        fixture.provider.modelsGate?.resume()
        await old.value
        XCTAssertEqual(model.models.map(\.id), ["gpt"])
    }

    func testConcisePromptAndTellMeMoreStayInSameChat() async throws {
        let fixture = try Fixture()
        fixture.provider.events = [.textDelta("Short answer"), .completed]
        let model = AppModel(coordinator: fixture.coordinator)
        try model.select(providerID: .ollama, modelID: "text")
        let originalID = model.thread?.id
        model.draft = "Why?"

        await model.submit()
        let firstRequest = try XCTUnwrap(fixture.provider.requests.last)
        XCTAssertTrue(firstRequest.messages.last?.text.contains("concise") == true)
        XCTAssertTrue(firstRequest.messages.last?.text.contains("Why?") == true)
        XCTAssertEqual(model.thread?.messages.first?.text, "Why?")

        await model.tellMeMore()
        let followup = try XCTUnwrap(fixture.provider.requests.last)
        XCTAssertEqual(model.thread?.id, originalID)
        XCTAssertTrue(followup.messages.last?.text.contains("more detail") == true)
        XCTAssertEqual(model.thread?.messages.count, 4)
    }

    func testAppModelIdentifiesOlderVisibleMessagesOutsideContext() async throws {
        let fixture = try Fixture()
        fixture.provider.contextWindowTokens = 1100
        let oldUser = ChatMessage(role: .user, text: String(repeating: "a", count: 100))
        let oldPet = ChatMessage(role: .pet, text: String(repeating: "b", count: 100))
        let recentUser = ChatMessage(role: .user, text: "recent question")
        let recentPet = ChatMessage(role: .pet, text: "recent answer")
        try fixture.store.save(ChatThread(providerID: .ollama, modelID: "text",
                                          messages: [oldUser, oldPet, recentUser, recentPet]))
        let model = AppModel(coordinator: try ChatCoordinator(providers: [.ollama: fixture.provider],
                                                               store: fixture.store, attachments: fixture.attachments))
        await model.loadModels(for: .ollama)

        XCTAssertEqual(model.excludedMessageIDs, [oldUser.id, oldPet.id])
    }

    func testLastSelectedPairSurvivesDeletingFinalChat() throws {
        let fixture = try Fixture()
        let suiteName = "PetChatTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(coordinator: fixture.coordinator, defaults: defaults)
        try model.select(providerID: .chatGPT, modelID: "gpt")
        try model.deleteCurrentChat()

        let restored = AppModel(coordinator: try ChatCoordinator(providers: [.chatGPT: fixture.otherProvider],
                                                                  store: fixture.store, attachments: fixture.attachments),
                                defaults: defaults)
        try restored.newChat()
        XCTAssertEqual(restored.thread?.providerID, .chatGPT)
        XCTAssertEqual(restored.thread?.modelID, "gpt")
    }

    func testLateChatGPTConnectionCannotReplaceOllamaCatalog() async throws {
        let fixture = try Fixture()
        let gate = AuthGate()
        let started = expectation(description: "sign-in started")
        gate.onStart = { started.fulfill() }
        let model = AppModel(coordinator: fixture.coordinator, signIn: { await gate.wait() })
        let connecting = Task { await model.connectChatGPT() }
        await fulfillment(of: [started], timeout: 2)

        await model.loadModels(for: .ollama)
        gate.resume()
        await connecting.value
        XCTAssertEqual(model.models.map(\.id), ["text"])
    }

    func testDuplicateAttachmentIDDoesNotCrashOrReadAnotherThread() async throws {
        let fixture = try Fixture()
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")
        let image = try fixture.attachments.save(Data([1]), threadID: thread.id)

        try await fixture.coordinator.send(text: "Look", attachmentIDs: [image, image], threadID: thread.id)

        XCTAssertEqual(fixture.provider.requests.last?.imageData, [image: Data([1])])
    }

    func testTellMeMoreDoesNotSubmitPendingImage() async throws {
        let fixture = try Fixture()
        let model = AppModel(coordinator: fixture.coordinator)
        try model.select(providerID: .ollama, modelID: "text")
        model.draft = "Why?"
        await model.submit()
        let thread = try XCTUnwrap(model.thread)
        let image = try fixture.attachments.save(Data([1]), threadID: thread.id)
        model.attachmentIDs = [image]

        await model.tellMeMore()

        XCTAssertEqual(fixture.provider.requests.count, 1)
        XCTAssertEqual(model.attachmentIDs, [image])
    }

    func testStopDuringModelDiscoveryPreventsLateGeneration() async throws {
        let fixture = try Fixture()
        let started = expectation(description: "model discovery started")
        fixture.provider.holdModels = true
        fixture.provider.onModels = { started.fulfill() }
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")
        let send = Task { try await fixture.coordinator.send(text: "Question", attachmentIDs: [], threadID: thread.id) }
        await fulfillment(of: [started], timeout: 2)

        try await fixture.coordinator.stop(threadID: thread.id)
        fixture.provider.modelsGate?.resume()
        _ = try? await send.value

        XCTAssertTrue(fixture.provider.requests.isEmpty)
        XCTAssertEqual(try fixture.store.load().first?.messages, [])
    }

    func testStopDuringDiscoveryAllowsRetryBeforeOldLookupReturns() async throws {
        let fixture = try Fixture()
        let model = AppModel(coordinator: fixture.coordinator)
        try model.select(providerID: .ollama, modelID: "text")
        model.draft = "Earlier"
        await model.submit()
        let started = expectation(description: "old discovery started")
        fixture.provider.holdModels = true
        fixture.provider.onModels = { started.fulfill() }
        model.draft = "Retry this"
        let old = Task { await model.submit() }
        await fulfillment(of: [started], timeout: 2)

        await model.stop()
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.draft, "Retry this")
        fixture.provider.holdModels = false
        await model.retry()
        fixture.provider.modelsGate?.resume()
        await old.value

        XCTAssertEqual(fixture.provider.requests.count, 2)
        XCTAssertEqual(model.thread?.messages.map(\.text).filter { $0 == "Retry this" }.count, 1)
        XCTAssertEqual(model.draft, "")
    }

    func testPostCommitAttachmentCleanupFailureCannotResurrectDeletedChat() async throws {
        let fixture = try Fixture(removeItem: { _ in throw TestFailure.disk })
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "vision")
        let image = try fixture.attachments.save(Data([1]), threadID: thread.id)

        XCTAssertThrowsError(try fixture.coordinator.deleteThread(thread.id)) { XCTAssertTrue($0 is TestFailure) }
        XCTAssertTrue(try fixture.store.load().isEmpty)
        XCTAssertFalse(fixture.coordinator.threads.contains { $0.id == thread.id })
        do {
            try await fixture.coordinator.send(text: "Resurrect?", attachmentIDs: [], threadID: thread.id)
            XCTFail("Deleted chat was sent")
        } catch { XCTAssertTrue(fixture.provider.requests.isEmpty) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory
            .appendingPathComponent(".pending-deletion").appendingPathComponent(thread.id.uuidString)
            .appendingPathComponent(image.uuidString).path))
    }
}

@MainActor private final class AuthGate {
    var onStart: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            onStart?()
        }
    }
    func resume() { continuation?.resume() }
}

private enum TestFailure: Error { case disconnected, disk }

@MainActor
private final class Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let attachments: AttachmentStore
    let store: LocalChatStore
    let provider = ScriptedProvider(id: .ollama)
    let otherProvider = ScriptedProvider(id: .chatGPT)
    let snapshots = SnapshotBox()
    lazy var coordinator = try! ChatCoordinator(providers: [.ollama: provider, .chatGPT: otherProvider], store: store, attachments: attachments)

    init(removeItem: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        attachments = AttachmentStore(root: directory, removeItem: removeItem)
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let snapshots = snapshots
        store = try LocalChatStore(container: container, attachments: attachments, saveContext: { context in
            if snapshots.failNextSave { snapshots.failNextSave = false; throw TestFailure.disk }
            try context.save()
            snapshots.threads += try context.fetch(FetchDescriptor<ChatRecord>()).map { try $0.thread() }
        })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor private final class SnapshotBox {
    var threads: [ChatThread] = []
    var failNextSave = false
}

private final class ScriptedProvider: ChatProvider, @unchecked Sendable {
    let providerID: ProviderID
    var events: [GenerationEvent] = [.completed]
    var requests: [GenerationRequest] = []
    var holdOpen = false
    var failure: Error?
    var onStream: (() -> Void)?
    var continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?
    var holdModels = false
    var onModels: (() -> Void)?
    var modelsGate: CheckedContinuation<Void, Never>?
    var cancelled = false
    var contextWindowTokens = 4096

    init(id: ProviderID) { providerID = id }
    func availableModels() async throws -> [ProviderModel] {
        if holdModels {
            await withCheckedContinuation { continuation in
                modelsGate = continuation
                onModels?()
            }
        }
        return [ProviderModel(id: providerID == .ollama ? "text" : "gpt", displayName: "Test", supportsImages: true, contextWindowTokens: contextWindowTokens)]
    }
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            events.forEach { continuation.yield($0) }
            onStream?()
            if let failure { continuation.finish(throwing: failure) }
            else if !holdOpen { continuation.finish() }
        }
    }
    func cancel(_ requestID: UUID) async {
        cancelled = true
        continuation?.finish(throwing: CancellationError())
    }
}
