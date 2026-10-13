import SwiftData
import AppKit
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
        XCTAssertEqual(request.model.id, "gpt")
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertTrue(request.messages[0].text.hasSuffix("second question"))
        XCTAssertTrue(try XCTUnwrap(fixture.store.load().first { $0.id == second.id }).messages.first?.text == "second question")
    }

    func testDeletedThreadCannotBeSentAndDeletesItsAttachments() async throws {
        let fixture = try Fixture()
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "vision")
        let image = try fixture.attachments.save(testPNG(), threadID: thread.id)

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

    func testRestartRestoresFailedQuestionAndImageForRetry() async throws {
        let fixture = try Fixture()
        fixture.provider.events = [.textDelta("Partial")]
        fixture.provider.failure = TestFailure.disconnected
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")
        let image = try fixture.attachments.save(testPNG(), threadID: thread.id)
        try? await fixture.coordinator.send(text: "Explain this", attachmentIDs: [image], threadID: thread.id)
        let restored = try ChatCoordinator(providers: [.ollama: fixture.provider], store: fixture.store,
                                           attachments: fixture.attachments)
        let model = AppModel(coordinator: restored, defaults: fixture.defaults)
        XCTAssertEqual(model.draft, "Explain this")
        XCTAssertEqual(model.attachmentIDs, [image])
        XCTAssertNotNil(model.errorMessage)
        await model.loadModels(for: .ollama)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.canRetrySubmission)
        fixture.provider.failure = nil
        fixture.provider.events = [.textDelta("Complete"), .completed]
        await model.submit()
        XCTAssertEqual(model.thread?.messages.map(\.text), ["Explain this", "Complete"])
        XCTAssertEqual(fixture.provider.requests.last?.imageData, [image: testPNG()])
    }

    func testNewChatDeletesAbandonedImagesButPreservesFailedTurnImages() async throws {
        for failed in [false, true] {
            let fixture = try Fixture()
            let model = AppModel(coordinator: fixture.coordinator, defaults: fixture.defaults)
            try model.select(providerID: .ollama, modelID: "text")
            let oldID = try XCTUnwrap(model.currentThreadID)
            try model.attachImage(testPNG())
            let image = try XCTUnwrap(model.attachmentIDs.first)
            if failed {
                fixture.provider.failure = TestFailure.disconnected
                await model.submit()
            }
            try model.newChat()
            if failed { XCTAssertEqual(try fixture.attachments.load(image, threadID: oldID), testPNG()) }
            else { XCTAssertThrowsError(try fixture.attachments.load(image, threadID: oldID)) }
            XCTAssertTrue(model.attachmentIDs.isEmpty)
        }
    }

    func testAppModelKeepsDraftAndAttachmentAfterProviderError() async throws {
        let fixture = try Fixture()
        fixture.provider.failure = TestFailure.disconnected
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        let thread = try XCTUnwrap(model.thread)
        let image = try fixture.attachments.save(testPNG(1), threadID: thread.id)
        model.draft = "What is this?"
        model.attachmentIDs = [image]

        await model.submit()

        XCTAssertEqual(model.draft, "What is this?")
        XCTAssertEqual(model.attachmentIDs, [image])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try fixture.attachments.load(image, threadID: thread.id), testPNG(1))
    }

    func testChangingModelStartsEmptyThread() throws {
        let fixture = try Fixture()
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
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
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        model.draft = "Question"
        await model.submit()
        fixture.provider.events = [.textDelta("Working"), .completed]
        fixture.provider.failure = nil

        await model.submit()

        XCTAssertEqual(fixture.provider.requests.last?.messages.count, 1)
        XCTAssertTrue(fixture.provider.requests.last?.messages[0].text.hasSuffix("Question") == true)
        XCTAssertEqual(model.thread?.messages.map(\.text), ["Question", "Working"])
        XCTAssertEqual(model.draft, "")
    }

    func testRegenerateReplacesLastReplyKeepingHistoryAndImages() async throws {
        let fixture = try Fixture()
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")
        fixture.provider.events = [.textDelta("First answer"), .completed]
        try await fixture.coordinator.send(text: "First", attachmentIDs: [], threadID: thread.id)
        let image = try fixture.attachments.save(testPNG(1), threadID: thread.id)
        fixture.provider.events = [.textDelta("Old answer"), .completed]
        try await fixture.coordinator.send(text: "Second", attachmentIDs: [image], threadID: thread.id)
        let question = try XCTUnwrap(fixture.coordinator.threads.first?.messages[2])
        fixture.provider.events = [.textDelta("Fresh answer"), .completed]

        try await fixture.coordinator.regenerateLastReply(threadID: thread.id)

        let saved = try XCTUnwrap(fixture.store.load().first)
        XCTAssertEqual(saved.messages.map(\.text), ["First", "First answer", "Second", "Fresh answer"])
        XCTAssertEqual(saved.messages[2].id, question.id)
        XCTAssertEqual(saved.messages[2].attachmentIDs, [image])
        XCTAssertEqual(saved.messages.last?.status, .complete)
        XCTAssertEqual(try fixture.attachments.load(image, threadID: thread.id), testPNG(1))
        let request = try XCTUnwrap(fixture.provider.requests.last)
        XCTAssertEqual(request.imageData, [image: testPNG(1)])
        XCTAssertEqual(request.messages.count, 3)
        XCTAssertTrue(request.messages.last?.text.hasSuffix("Second") == true)
        XCTAssertFalse(request.messages.contains { $0.text.contains("Old answer") })
    }

    func testRegenerateReplacesStoppedAndFailedReplies() async throws {
        for stopped in [false, true] {
            let fixture = try Fixture()
            let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")
            fixture.provider.events = [.textDelta("Partial")]
            if stopped {
                let started = expectation(description: "provider started")
                fixture.provider.holdOpen = true
                fixture.provider.onStream = { started.fulfill() }
                let send = Task { try await fixture.coordinator.send(text: "Hi", attachmentIDs: [], threadID: thread.id) }
                await fulfillment(of: [started], timeout: 2)
                try await fixture.coordinator.stop(threadID: thread.id)
                try await send.value
                fixture.provider.holdOpen = false
                fixture.provider.onStream = nil
            } else {
                fixture.provider.failure = TestFailure.disconnected
                try? await fixture.coordinator.send(text: "Hi", attachmentIDs: [], threadID: thread.id)
                fixture.provider.failure = nil
            }
            XCTAssertEqual(fixture.coordinator.threads.first?.messages.last?.status, stopped ? .stopped : .failed)
            fixture.provider.events = [.textDelta("Done"), .completed]

            try await fixture.coordinator.regenerateLastReply(threadID: thread.id)

            let saved = try XCTUnwrap(fixture.store.load().first)
            XCTAssertEqual(saved.messages.map(\.text), ["Hi", "Done"])
            XCTAssertEqual(saved.messages.last?.status, .complete)
        }
    }

    func testRegenerateWithoutLastReplyThrowsWithoutGenerating() async throws {
        let fixture = try Fixture()
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")

        do {
            try await fixture.coordinator.regenerateLastReply(threadID: thread.id)
            XCTFail("Regenerated an empty chat")
        } catch ChatCoordinator.Error.nothingToRegenerate {}
        XCTAssertTrue(fixture.provider.requests.isEmpty)
        XCTAssertEqual(fixture.coordinator.threads.first?.messages, [])
    }

    func testRegenerateWhileAnsweringThrowsBusy() async throws {
        let fixture = try Fixture()
        let started = expectation(description: "provider started")
        fixture.provider.events = [.textDelta("Partial")]
        fixture.provider.holdOpen = true
        fixture.provider.onStream = { started.fulfill() }
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")
        let send = Task { try await fixture.coordinator.send(text: "Hi", attachmentIDs: [], threadID: thread.id) }
        await fulfillment(of: [started], timeout: 2)

        do {
            try await fixture.coordinator.regenerateLastReply(threadID: thread.id)
            XCTFail("Regenerated while busy")
        } catch ChatCoordinator.Error.busy {}
        XCTAssertEqual(fixture.provider.requests.count, 1)
        try await fixture.coordinator.stop(threadID: thread.id)
        try await send.value
    }

    func testAppModelRegenerateFailureRetriesRegenerateNotDraft() async throws {
        let fixture = try Fixture()
        fixture.provider.events = [.textDelta("Old"), .completed]
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        XCTAssertFalse(model.canRegenerate)
        model.draft = "Question"
        await model.submit()
        XCTAssertTrue(model.canRegenerate)
        model.draft = "Unsent draft"
        fixture.provider.events = [.textDelta("broken")]
        fixture.provider.failure = TestFailure.disconnected

        await model.regenerateLastReply()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.canRetrySubmission)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.draft, "Unsent draft")
        XCTAssertEqual(model.thread?.messages.last?.status, .failed)
        fixture.provider.events = [.textDelta("Fresh"), .completed]
        fixture.provider.failure = nil

        await model.retry()

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.canRetrySubmission)
        XCTAssertEqual(model.thread?.messages.map(\.text), ["Question", "Fresh"])
        XCTAssertEqual(model.draft, "Unsent draft")
        XCTAssertTrue(fixture.provider.requests.last?.messages.last?.text.hasSuffix("Question") == true)
    }

    func testAppModelRetryAfterSubmitFailureResubmitsDraft() async throws {
        let fixture = try Fixture()
        fixture.provider.failure = TestFailure.disconnected
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        model.draft = "Question"
        await model.submit()
        XCTAssertTrue(model.canRetrySubmission)
        fixture.provider.failure = nil
        fixture.provider.events = [.textDelta("Answer"), .completed]

        await model.retry()

        XCTAssertEqual(model.thread?.messages.map(\.text), ["Question", "Answer"])
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
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
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

    func testSuccessfulImageSendClearsSubmittedPreviewWhileKeepingEditedText() async throws {
        let fixture = try Fixture()
        let started = expectation(description: "image stream started")
        fixture.provider.holdOpen = true
        fixture.provider.onStream = { started.fulfill() }
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        let threadID = try XCTUnwrap(model.currentThreadID)
        model.draft = "Original image question"
        try model.attachImage(testPNG())
        let image = try XCTUnwrap(model.attachmentIDs.first)
        let send = Task { await model.submit() }
        await fulfillment(of: [started], timeout: 2)
        model.draft = "Next text question"
        fixture.provider.continuation?.yield(.completed)
        fixture.provider.continuation?.finish()
        await send.value

        XCTAssertEqual(model.draft, "Next text question")
        XCTAssertTrue(model.attachmentIDs.isEmpty)
        XCTAssertEqual(model.thread?.messages.first?.attachmentIDs, [image])
        XCTAssertEqual(try fixture.attachments.load(image, threadID: threadID), testPNG())
        fixture.provider.holdOpen = false
        fixture.provider.onStream = nil
        await model.submit()
        XCTAssertEqual(fixture.provider.requests.count, 2)
        XCTAssertEqual(fixture.provider.requests.last?.imageData, [:])
        XCTAssertEqual(fixture.provider.requests.last?.messages.last?.attachmentIDs, [])
        XCTAssertEqual(try fixture.attachments.load(image, threadID: threadID), testPNG())
    }

    func testOlderModelDiscoveryCannotReplaceNewProviderModels() async throws {
        let fixture = try Fixture()
        let started = expectation(description: "old discovery started")
        fixture.provider.holdModels = true
        fixture.provider.onModels = { started.fulfill() }
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
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
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
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
                                                               store: fixture.store, attachments: fixture.attachments), defaults: fixture.defaults)
        await model.loadModels(for: .ollama)

        XCTAssertEqual(model.excludedMessageIDs, [oldUser.id, oldPet.id])
    }

    func testTextSizeRestoresFromInjectedDefaultsAndRejectsUnknownSavedSize() throws {
        let fixture = try Fixture()
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        XCTAssertEqual(model.textSize, 13)
        model.textSize = 17
        let restored = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        XCTAssertEqual(restored.textSize, 17)
        fixture.defaults.set(100_000, forKey: "PetChat.textSize")
        let invalid = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        XCTAssertEqual(invalid.textSize, 13)
    }

    func testRestartRestoresChatProviderIdentityWithoutDiscovery() throws {
        let fixture = try Fixture()
        let original = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try original.select(providerID: .chatGPT, modelID: "gpt")
        let restored = AppModel(coordinator: try ChatCoordinator(providers: [.chatGPT: fixture.otherProvider],
            store: fixture.store, attachments: fixture.attachments), defaults: fixture.defaults)
        XCTAssertEqual(restored.currentThreadID, original.currentThreadID)
        XCTAssertEqual(restored.thread?.providerID, .chatGPT)
        XCTAssertEqual(restored.selectedModelID, "gpt")
        XCTAssertTrue(fixture.otherProvider.requests.isEmpty)
        XCTAssertEqual(fixture.otherProvider.modelDiscoveryCount, 0)
    }

    func testShutdownStopsStreamingAndPreservesDraftHistoryAndProvider() async throws {
        let fixture = try Fixture()
        fixture.otherProvider.holdOpen = true
        fixture.otherProvider.events = [.textDelta("Partial")]
        let started = expectation(description: "stream started")
        fixture.otherProvider.onStream = { started.fulfill() }
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .chatGPT, modelID: "gpt")
        model.draft = "Keep my question"
        let submission = Task { await model.submit() }
        await fulfillment(of: [started], timeout: 2)
        await model.shutdown()
        await submission.value
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(fixture.otherProvider.cancelled)
        XCTAssertEqual(model.draft, "Keep my question")
        XCTAssertEqual(model.thread?.providerID, .chatGPT)
        XCTAssertEqual(model.thread?.messages.last?.status, .stopped)
        XCTAssertEqual(try fixture.store.load().last?.messages.last?.status, .stopped)
    }

    func testShutdownStopsAllActiveProviderStreams() async throws {
        let fixture = try Fixture()
        for provider in [fixture.provider, fixture.otherProvider] {
            provider.holdOpen = true
            provider.events = [.textDelta("Partial")]
        }
        let started = expectation(description: "both streams started")
        started.expectedFulfillmentCount = 2
        fixture.provider.onStream = { started.fulfill() }
        fixture.otherProvider.onStream = { started.fulfill() }
        let first = try fixture.coordinator.newThread(providerID: .ollama, modelID: "text")
        let second = try fixture.coordinator.newThread(providerID: .chatGPT, modelID: "gpt")
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        let firstSend = Task { try await fixture.coordinator.send(text: "First", attachmentIDs: [], threadID: first.id) }
        let secondSend = Task { try await fixture.coordinator.send(text: "Second", attachmentIDs: [], threadID: second.id) }
        await fulfillment(of: [started], timeout: 2)
        await model.shutdown()
        try await firstSend.value
        try await secondSend.value
        XCTAssertTrue(fixture.provider.cancelled)
        XCTAssertTrue(fixture.otherProvider.cancelled)
        XCTAssertEqual(try fixture.store.load().map { $0.messages.last?.status }, [.stopped, .stopped])
    }

    func testShutdownDiscardsLateCaptureAndModelDiscovery() async throws {
        let fixture = try Fixture()
        let gate = AuthGate()
        let captureStarted = expectation(description: "capture started")
        gate.onStart = { captureStarted.fulfill() }
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        model.draft = "Keep draft"
        let capture = Task { await model.captureImage(using: { await gate.wait(); return testPNG() }) }
        await fulfillment(of: [captureStarted], timeout: 2)
        fixture.provider.holdModels = true
        let modelsStarted = expectation(description: "models started")
        fixture.provider.onModels = { modelsStarted.fulfill() }
        let discovery = Task { await model.loadModels(for: .ollama) }
        await fulfillment(of: [modelsStarted], timeout: 2)
        await model.shutdown()
        gate.resume()
        fixture.provider.modelsGate?.resume()
        await capture.value
        await discovery.value
        XCTAssertTrue(model.attachmentIDs.isEmpty)
        XCTAssertTrue(model.models.isEmpty)
        XCTAssertTrue(fixture.provider.modelDiscoveryWasCancelled)
        XCTAssertEqual(model.draft, "Keep draft")
        await model.submit()
        XCTAssertTrue(fixture.provider.requests.isEmpty)
    }

    func testShutdownCancelsPendingSubmissionDiscoveryWithoutGenerating() async throws {
        let fixture = try Fixture()
        fixture.provider.holdModels = true
        let started = expectation(description: "send discovery started")
        fixture.provider.onModels = { started.fulfill() }
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        model.draft = "Keep unsent question"
        let pending = Task { await model.submit() }
        await fulfillment(of: [started], timeout: 2)
        await model.shutdown()
        fixture.provider.modelsGate?.resume()
        await pending.value
        XCTAssertTrue(fixture.provider.modelDiscoveryWasCancelled)
        XCTAssertTrue(fixture.provider.requests.isEmpty)
        XCTAssertTrue(model.thread?.messages.isEmpty == true)
        XCTAssertEqual(model.draft, "Keep unsent question")
    }

    func testSignOutInvalidatesPendingConnectWithoutDiscoveryOrDraftLoss() async throws {
        let fixture = try Fixture()
        let gate = AuthGate()
        let started = expectation(description: "connect started")
        gate.onStart = { started.fulfill() }
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults, signIn: { await gate.wait() })
        try model.select(providerID: .chatGPT, modelID: "gpt")
        model.draft = "Keep draft"
        let connection = Task { await model.connectChatGPT() }
        await fulfillment(of: [started], timeout: 2)
        await model.signOutChatGPT()
        gate.resume()
        await connection.value
        XCTAssertTrue(model.models.isEmpty)
        XCTAssertEqual(model.draft, "Keep draft")
        XCTAssertEqual(model.thread?.providerID, .chatGPT)
        XCTAssertTrue(fixture.otherProvider.requests.isEmpty)
        XCTAssertEqual(fixture.otherProvider.modelDiscoveryCount, 0)
    }

    func testSignOutStopsGenerationBeforeRevocationAndBlocksNewChatGPTRequests() async throws {
        let fixture = try Fixture()
        fixture.otherProvider.holdOpen = true
        let streamStarted = expectation(description: "generation started")
        fixture.otherProvider.onStream = { streamStarted.fulfill() }
        let gate = AuthGate()
        let revocationStarted = expectation(description: "revocation started")
        gate.onStart = { revocationStarted.fulfill() }
        var signIns = 0
        var signOuts = 0
        let model = AppModel(coordinator: fixture.coordinator, defaults: fixture.defaults, signIn: {
            signIns += 1
        }, signOut: {
            signOuts += 1
            XCTAssertTrue(fixture.otherProvider.cancelled)
            await gate.wait()
            throw ChatGPTError.revocationUnconfirmed
        })
        try model.select(providerID: .chatGPT, modelID: "gpt")
        model.draft = "Keep question"
        let submission = Task { await model.submit() }
        await fulfillment(of: [streamStarted], timeout: 2)
        let signOut = Task { await model.signOutChatGPT() }
        await fulfillment(of: [revocationStarted], timeout: 2)
        XCTAssertTrue(model.isSigningOutChatGPT)
        await model.submit()
        await model.connectChatGPT()
        await model.loadModels(for: .chatGPT)
        await model.signOutChatGPT()
        XCTAssertEqual(fixture.otherProvider.requests.count, 1)
        XCTAssertEqual(signIns, 0)
        XCTAssertEqual(signOuts, 1)
        gate.resume()
        await signOut.value
        await submission.value
        XCTAssertFalse(model.isSigningOutChatGPT)
        XCTAssertEqual(model.draft, "Keep question")
        XCTAssertEqual(model.thread?.messages.last?.status, .stopped)
        XCTAssertTrue(model.errorMessage?.contains("remote revocation") == true)
    }

    func testOverlappingConnectionsKeepFirstAttemptAndLoadItsModels() async throws {
        let fixture = try Fixture()
        let gate = AuthGate()
        let started = expectation(description: "connection started")
        gate.onStart = { started.fulfill() }
        var attempts = 0
        let model = AppModel(coordinator: fixture.coordinator, defaults: fixture.defaults, signIn: {
            attempts += 1
            guard attempts == 1 else { throw ChatGPTError.signInFailed }
            await gate.wait()
        })
        let first = Task { await model.connectChatGPT() }
        await fulfillment(of: [started], timeout: 2)
        await model.connectChatGPT()
        gate.resume()
        await first.value
        XCTAssertEqual(model.models.map(\.id), ["gpt"])
        XCTAssertNil(model.errorMessage)
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
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults, signIn: { await gate.wait() })
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
        let image = try fixture.attachments.save(testPNG(1), threadID: thread.id)

        try await fixture.coordinator.send(text: "Look", attachmentIDs: [image, image], threadID: thread.id)

        XCTAssertEqual(fixture.provider.requests.last?.imageData, [image: testPNG(1)])
    }

    func testTellMeMoreDoesNotSubmitPendingImage() async throws {
        let fixture = try Fixture()
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        model.draft = "Why?"
        await model.submit()
        let thread = try XCTUnwrap(model.thread)
        let image = try fixture.attachments.save(testPNG(1), threadID: thread.id)
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
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
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
        await model.submit()
        fixture.provider.modelsGate?.resume()
        await old.value

        XCTAssertEqual(fixture.provider.requests.count, 2)
        XCTAssertEqual(model.thread?.messages.map(\.text).filter { $0 == "Retry this" }.count, 1)
        XCTAssertEqual(model.draft, "")
    }

    func testPasteCreatesPreviewWithoutSendingAndRemovalDeletesOnlyUnsubmittedImage() throws {
        let fixture = try Fixture()
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(testPNG(), forType: .png)
        try model.pasteImage(from: pasteboard)
        let image = try XCTUnwrap(model.attachmentIDs.first)
        XCTAssertNotNil(model.imageData(for: image))
        XCTAssertTrue(model.thread!.messages.isEmpty)
        XCTAssertTrue(fixture.provider.requests.isEmpty)
        try model.removeAttachment(image)
        XCTAssertTrue(model.attachmentIDs.isEmpty)
        XCTAssertThrowsError(try fixture.attachments.load(image, threadID: model.currentThreadID!))
    }

    func testInvalidPastePreservesDraftAndImages() throws {
        let fixture = try Fixture()
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        try model.attachImage(testPNG())
        let images = model.attachmentIDs
        model.draft = "Keep"
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(Data("broken".utf8), forType: .png)
        XCTAssertThrowsError(try model.pasteImage(from: pasteboard))
        XCTAssertEqual(model.draft, "Keep")
        XCTAssertEqual(model.attachmentIDs, images)
    }

    func testRemovingFailedTurnPreviewPreservesHistoricalImage() async throws {
        let fixture = try Fixture()
        fixture.provider.failure = TestFailure.disconnected
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        try model.attachImage(testPNG())
        let image = try XCTUnwrap(model.attachmentIDs.first)
        await model.submit()
        XCTAssertEqual(model.attachmentIDs, [image])
        try model.removeAttachment(image)
        XCTAssertEqual(model.thread?.messages.first?.attachmentIDs, [image])
        XCTAssertEqual(try fixture.attachments.load(image, threadID: model.currentThreadID!), testPNG())
    }

    func testImagesClearOnlyAfterSuccessAndNeverResendOnNextTurn() async throws {
        let fixture = try Fixture()
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        try model.attachImage(testPNG())
        let image = try XCTUnwrap(model.attachmentIDs.first)
        await model.submit()
        XCTAssertTrue(model.attachmentIDs.isEmpty)
        XCTAssertEqual(fixture.provider.requests.last?.imageData, [image: testPNG()])
        model.draft = "Next"
        await model.submit()
        XCTAssertEqual(fixture.provider.requests.last?.imageData, [:])
        XCTAssertEqual(try fixture.attachments.load(image, threadID: model.currentThreadID!), testPNG())
    }

    func testUnsupportedModelKeepsDraftAndImagesWithoutPersistingTurn() async throws {
        let fixture = try Fixture()
        fixture.provider.supportsImages = false
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        model.draft = "Look"
        try model.attachImage(testPNG())
        let images = model.attachmentIDs
        await model.submit()
        XCTAssertEqual(model.draft, "Look")
        XCTAssertEqual(model.attachmentIDs, images)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.thread!.messages.isEmpty)
        XCTAssertTrue(fixture.provider.requests.isEmpty)
    }

    func testCaptureSuccessAddsPreviewWithoutSubmittingAndCancelKeepsDraft() async throws {
        let fixture = try Fixture()
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        model.draft = "Keep"
        await model.captureImage(using: { testPNG() })
        let images = model.attachmentIDs
        XCTAssertEqual(images.count, 1)
        XCTAssertNotNil(model.imageData(for: images[0]))
        XCTAssertTrue(model.thread!.messages.isEmpty)
        XCTAssertTrue(fixture.provider.requests.isEmpty)
        await model.captureImage(using: { nil })
        XCTAssertEqual(model.attachmentIDs, images)
        XCTAssertEqual(model.draft, "Keep")
        XCTAssertFalse(model.isCapturing)
    }

    func testLateCaptureCannotReattachAfterSwitchingAwayAndBack() async throws {
        let fixture = try Fixture()
        let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        let originalID = model.currentThreadID
        let gate = AuthGate()
        let started = expectation(description: "capture started")
        gate.onStart = { started.fulfill() }
        let task = Task { await model.captureImage(using: { await gate.wait(); return testPNG() }) }
        await fulfillment(of: [started], timeout: 2)
        try model.newChat()
        try model.deleteCurrentChat()
        XCTAssertEqual(model.currentThreadID, originalID)
        gate.resume()
        await task.value
        XCTAssertTrue(model.attachmentIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testLateCaptureAfterThreadOrProviderChangeIsDiscarded() async throws {
        for changeProvider in [false, true] {
            let fixture = try Fixture()
            let model = AppModel(coordinator: fixture.coordinator, auth: fixture.auth, defaults: fixture.defaults)
            try model.select(providerID: .ollama, modelID: "text")
            let gate = AuthGate()
            let started = expectation(description: "capture started")
            gate.onStart = { started.fulfill() }
            let task = Task { await model.captureImage(using: { await gate.wait(); return testPNG() }) }
            await fulfillment(of: [started], timeout: 2)
            if changeProvider { try model.select(providerID: .chatGPT, modelID: "gpt") }
            else { try model.newChat() }
            gate.resume()
            await task.value
            XCTAssertTrue(model.attachmentIDs.isEmpty)
            XCTAssertTrue(model.thread!.messages.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        }
    }

    func testNewChatSwitchesEvenWhenAbandonedImageCleanupPartlyFails() throws {
        var removals = 0
        let fixture = try Fixture(removeItem: { url in
            removals += 1
            if removals > 1 { throw TestFailure.disk }
            try FileManager.default.removeItem(at: url)
        })
        let model = AppModel(coordinator: fixture.coordinator, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        let oldID = try XCTUnwrap(model.currentThreadID)
        try model.attachImage(testPNG(1))
        try model.attachImage(testPNG(2))
        model.draft = "abandoned"

        try model.newChat()

        XCTAssertNotEqual(model.currentThreadID, oldID)
        XCTAssertTrue(model.thread?.messages.isEmpty == true)
        XCTAssertTrue(model.attachmentIDs.isEmpty)
        XCTAssertEqual(model.draft, "")
    }

    func testCommittedDeleteWithCleanupFailureLeavesDeletedChat() throws {
        let fixture = try Fixture(removeItem: { _ in throw TestFailure.disk })
        let model = AppModel(coordinator: fixture.coordinator, defaults: fixture.defaults)
        try model.select(providerID: .ollama, modelID: "text")
        let first = try XCTUnwrap(model.currentThreadID)
        try model.newChat()
        let deleted = try XCTUnwrap(model.currentThreadID)
        try model.attachImage(testPNG())

        XCTAssertThrowsError(try model.deleteCurrentChat())

        XCTAssertEqual(model.currentThreadID, first)
        XCTAssertTrue(model.attachmentIDs.isEmpty)
        XCTAssertFalse(fixture.coordinator.threads.contains { $0.id == deleted })
        XCTAssertNoThrow(try model.newChat())
    }

    func testPostCommitAttachmentCleanupFailureCannotResurrectDeletedChat() async throws {
        let fixture = try Fixture(removeItem: { _ in throw TestFailure.disk })
        let thread = try fixture.coordinator.newThread(providerID: .ollama, modelID: "vision")
        let image = try fixture.attachments.save(testPNG(1), threadID: thread.id)

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
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let attachments: AttachmentStore
    let store: LocalChatStore
    let auth = ChatGPTOAuthClient(store: KeychainCredentialStore(service: "com.etre.pet-chat.coordinator-tests.\(UUID())"))
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
    var modelDiscoveryWasCancelled = false
    var modelDiscoveryCount = 0
    var cancelled = false
    var supportsImages = true
    var contextWindowTokens = 4096

    init(id: ProviderID) { providerID = id }
    func availableModels() async throws -> [ProviderModel] {
        modelDiscoveryCount += 1
        if holdModels {
            await withCheckedContinuation { continuation in
                modelsGate = continuation
                onModels?()
            }
        }
        modelDiscoveryWasCancelled = Task.isCancelled
        return [ProviderModel(id: providerID == .ollama ? "text" : "gpt", displayName: "Test", supportsImages: supportsImages, contextWindowTokens: contextWindowTokens)]
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
