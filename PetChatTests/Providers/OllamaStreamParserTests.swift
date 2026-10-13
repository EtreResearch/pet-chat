import Foundation
import SwiftData
import XCTest
@testable import PetChat

final class OllamaStreamParserTests: XCTestCase {
    @MainActor
    func testLengthLimitedAnswerKeepsPartialFailedTurnAndRetryDraft() async throws {
        MockOllamaURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/tags": return (200, Data(#"{"models":[{"name":"text:latest"}]}"#.utf8))
            case "/api/show": return (200, Data("{}".utf8))
            default: return (200, Data((
                #"{"model":"text:latest","message":{"role":"assistant","content":"partial"},"done":false}"# + "\n" +
                #"{"model":"text:latest","message":{"role":"assistant","content":" ending"},"done":true,"done_reason":"length"}"# + "\n"
            ).utf8))
            }
        }
        defer { MockOllamaURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOllamaURLProtocol.self]
        let provider = OllamaProvider(session: URLSession(configuration: configuration))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PetChat.LengthTests.\(UUID())"
        defer { try? FileManager.default.removeItem(at: root); UserDefaults().removePersistentDomain(forName: suite) }
        let attachments = AttachmentStore(root: root)
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try LocalChatStore(container: container, attachments: attachments)
        let coordinator = try ChatCoordinator(providers: [.ollama: provider], store: store, attachments: attachments)
        let model = AppModel(coordinator: coordinator, defaults: UserDefaults(suiteName: suite)!)
        try model.select(providerID: .ollama, modelID: "text:latest")
        model.draft = "Explain this"
        await model.submit()
        XCTAssertEqual(model.thread?.messages.last?.text, "partial ending")
        XCTAssertEqual(try store.load().last?.messages.last?.status, .failed)
        XCTAssertEqual(model.draft, "Explain this")
        XCTAssertTrue(model.canRetrySubmission)
    }

    func testMessageLessTerminalCompletesAfterDeltas() async throws {
        MockOllamaURLProtocol.handler = { request in
            if request.url?.path == "/api/show" { return (200, Data("{}".utf8)) }
            return (200, Data((
                #"{"model":"text:latest","message":{"role":"assistant","content":"answer"},"done":false}"# + "\n" +
                #"{"model":"text:latest","done":true,"total_duration":123}"# + "\n"
            ).utf8))
        }
        defer { MockOllamaURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOllamaURLProtocol.self]
        let provider = OllamaProvider(session: URLSession(configuration: configuration))
        let request = GenerationRequest(id: UUID(), model: .test("text:latest"), messages: [
            PromptMessage(role: .user, text: "Hi", attachmentIDs: [])
        ], imageData: [:])
        var events: [String] = []
        for try await event in provider.stream(request) {
            switch event {
            case .textDelta(let text): events.append(text)
            case .completed: events.append("completed")
            }
        }
        XCTAssertEqual(events, ["answer", "completed"])
    }

    func testTruncatedStreamThrowsWithoutCompletion() async throws {
        MockOllamaURLProtocol.handler = { request in
            if request.url?.path == "/api/show" { return (200, Data("{}".utf8)) }
            return (200, Data((#"{"model":"text:latest","message":{"role":"assistant","content":"partial"},"done":false}"# + "\n").utf8))
        }
        defer { MockOllamaURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOllamaURLProtocol.self]
        let provider = OllamaProvider(session: URLSession(configuration: configuration))
        let request = GenerationRequest(id: UUID(), model: .test("text:latest"), messages: [
            PromptMessage(role: .user, text: "Hi", attachmentIDs: [])
        ], imageData: [:])
        var completed = false
        do {
            for try await event in provider.stream(request) {
                if case .completed = event { completed = true }
            }
            XCTFail("Expected truncated stream error")
        } catch {
            XCTAssertFalse(completed)
        }
    }

    func testMalformedAndReorderedTerminalEventsNeverComplete() async throws {
        let invalidStreams = [
            #"{"model":"text:latest","done":false}"# + "\n",
            #"{"model":"text:latest","message":{"role":"assistant","content":""},"done":true}"# + "\n" +
                #"{"model":"text:latest","message":{"role":"assistant","content":"late"},"done":false}"# + "\n",
            #"{"model":"text:latest","message":{"role":"assistant","content":"ok"},"done":false}"# + "\n" + "not JSON\n"
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOllamaURLProtocol.self]
        let provider = OllamaProvider(session: URLSession(configuration: configuration))
        let request = GenerationRequest(id: UUID(), model: .test("text:latest"), messages: [
            PromptMessage(role: .user, text: "Hi", attachmentIDs: [])
        ], imageData: [:])
        defer { MockOllamaURLProtocol.handler = nil }
        for stream in invalidStreams {
            MockOllamaURLProtocol.handler = { request in
                if request.url?.path == "/api/show" { return (200, Data("{}".utf8)) }
                return (200, Data(stream.utf8))
            }
            var completed = false
            do {
                for try await event in provider.stream(request) {
                    if case .completed = event { completed = true }
                }
                XCTFail("Expected invalid stream error")
            } catch {
                XCTAssertFalse(completed)
            }
        }
    }

    func testOversizedLineFailsBeforeCompletion() async throws {
        MockOllamaURLProtocol.handler = { request in
            if request.url?.path == "/api/show" { return (200, Data("{}".utf8)) }
            return (200, Data(repeating: 65, count: 1_048_577))
        }
        defer { MockOllamaURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOllamaURLProtocol.self]
        let provider = OllamaProvider(session: URLSession(configuration: configuration))
        let request = GenerationRequest(id: UUID(), model: .test("text:latest"), messages: [
            PromptMessage(role: .user, text: "Hi", attachmentIDs: [])
        ], imageData: [:])
        do {
            for try await _ in provider.stream(request) {}
            XCTFail("Expected oversized line error")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("oversized"))
        }
    }
}
