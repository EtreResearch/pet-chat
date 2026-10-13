import Foundation
import Security
import SwiftData
import XCTest
@testable import PetChat

final class OpenAIPlanProviderTests: XCTestCase {
    private var services: [String] = []
    override func tearDown() {
        FakePlanURLProtocol.handler = nil
        FakePlanURLProtocol.expectStop(nil)
        for service in services {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }
        super.tearDown()
    }

    func testListsOnlyVisibleAccountModelsInServerOrder() async throws {
        let provider = try makeProvider()
        FakePlanURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
            return (200, Data(#"{"models":[{"slug":"vision","display_name":"Vision","visibility":"list","input_modalities":["text","image"]},{"slug":"hidden","display_name":"Hidden","visibility":"hidden"},{"slug":"text","display_name":"Text","visibility":"list","input_modalities":["text"]}]}"#.utf8))
        }
        let models = try await provider.availableModels()
        XCTAssertEqual(models, [
            ProviderModel(id: "vision", displayName: "Vision", supportsImages: true, contextWindowTokens: nil),
            ProviderModel(id: "text", displayName: "Text", supportsImages: false, contextWindowTokens: nil)
        ])
    }

    func testSendsOnlyCurrentImagesAndOrderedContextWithRequiredFlags() async throws {
        let provider = try makeProvider()
        let old = UUID(), current = UUID()
        FakePlanURLProtocol.handler = { request in
            if request.url?.path == "/v1/models" { return (200, Self.models) }
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
            let body = try JSONSerialization.jsonObject(with: request.testBody) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "vision")
            XCTAssertEqual(body["store"] as? Bool, false)
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertNil(body["previous_response_id"])
            let input = body["input"] as! [[String: Any]]
            XCTAssertEqual(input.count, 3)
            XCTAssertEqual(input[0]["content"] as? String, "Earlier")
            XCTAssertEqual(input[1]["role"] as? String, "assistant")
            let content = input[2]["content"] as! [[String: Any]]
            XCTAssertEqual(content[0]["text"] as? String, "Look")
            XCTAssertEqual(content[1]["type"] as? String, "input_image")
            XCTAssertTrue(content[1]["image_url"] as? String == "data:image/png;base64,\(Data([137,80,78,71,13,10,26,10,1]).base64EncodedString())")
            return (200, Self.sse([Self.created, Self.delta("Hi", sequence: 1, outputIndex: 1), Self.delta(" there", sequence: 2, outputIndex: 1), Self.completed("Hi there", sequence: 3).replacingOccurrences(of: #""output":["#, with: #""output":[{"type":"reasoning","id":"rs_test","summary":[]},"#)]))
        }
        let request = GenerationRequest(id: UUID(), model: .test("vision", images: true), messages: [
            PromptMessage(role: .user, text: "Earlier", attachmentIDs: [old]),
            PromptMessage(role: .assistant, text: "Prior answer", attachmentIDs: []),
            PromptMessage(role: .user, text: "Look", attachmentIDs: [current])
        ], imageData: [old: Data([9]), current: Data([137,80,78,71,13,10,26,10,1])])
        var deltas: [String] = []
        var completed = false
        for try await event in provider.stream(request) {
            switch event { case .textDelta(let text): deltas.append(text); case .completed: completed = true }
        }
        XCTAssertEqual(deltas, ["Hi", " there"])
        XCTAssertTrue(completed)
    }

    func testMissingModalityMetadataDefaultsToImagesButExplicitTextOnlyDoesNot() async throws {
        let provider = try makeProvider()
        FakePlanURLProtocol.handler = { _ in
            (200, Data(#"{"models":[{"slug":"legacy","display_name":"Legacy","visibility":"list"},{"slug":"alias","display_name":"Alias","visibility":"list","supported_input_modalities":["text","image"]},{"slug":"text","display_name":"Text","visibility":"list","input_modalities":["text"],"supported_input_modalities":["image"]},{"slug":"empty","display_name":"Empty","visibility":"list","input_modalities":[]}]}"#.utf8))
        }
        let models = try await provider.availableModels()
        XCTAssertEqual(models.map(\.supportsImages), [true, true, false, false])
    }

    func testRejectsEventsAfterCompletedFrame() async throws {
        for trailing in [Self.delta("late", sequence: 3), Self.completed("partial", sequence: 3),
                         #"{"type":"response.failed","sequence_number":3,"response":{"id":"resp_test","object":"response","status":"failed","error":{"code":"usage_limit"}}}"#] {
            try await assertRejected([Self.created, Self.delta("partial", sequence: 1),
                                      Self.completed("partial", sequence: 2), trailing])
        }
    }

    func testRejectsTerminalTextDifferentFromStreamedText() async throws {
        for terminal in [Self.completed("partial plus missing text", sequence: 2),
                         Self.completed("different", sequence: 2),
                         Self.completed("partial", sequence: 2).replacingOccurrences(of: "msg_test", with: "msg_other")] {
            try await assertRejected([Self.created, Self.delta("partial", sequence: 1), terminal])
        }
    }

    func testFailedIncompleteAndTruncatedStreamsNeverComplete() async throws {
        for suffix in [#"{"type":"response.failed","sequence_number":2,"response":{"id":"resp_test","object":"response","status":"failed","error":{"code":"usage_limit"}}}"#,
                       #"{"type":"response.incomplete","sequence_number":2,"response":{"id":"resp_test","object":"response","status":"incomplete"}}"#, ""] {
            try await assertRejected([Self.created, Self.delta("partial", sequence: 1)] + (suffix.isEmpty ? [] : [suffix]))
        }
    }

    func testRejectsDuplicateDecreasingMissingAndNegativeSequences() async throws {
        for second in [Self.delta("second", sequence: 1), Self.delta("second", sequence: 0),
                       #"{"type":"response.output_text.delta","delta":"second"}"#,
                       Self.delta("second", sequence: -1)] {
            try await assertRejected([Self.created, Self.delta("partial", sequence: 1), second,
                                      Self.completed("partialsecond", sequence: 3)])
        }
    }

    func testRejectsMalformedInconsistentAndTruncatedCompletion() async throws {
        for terminal in [#"{"type":"response.completed","sequence_number":2}"#,
                         Self.completed("partial", sequence: 2).replacingOccurrences(of: "completed", with: "in_progress", options: [], range: nil).replacingOccurrences(of: "response.in_progress", with: "response.completed"),
                         Self.completed("partial", sequence: 2).replacingOccurrences(of: "resp_test", with: "resp_other"),
                         Self.completed("partial", sequence: 2).replacingOccurrences(of: #""object":"response""#, with: #""object":"other""#),
                         Self.completed("partial", sequence: 2).replacingOccurrences(of: #""output":["#, with: #""missing_output":["#),
                         Self.completed("partial", sequence: 2).replacingOccurrences(of: #""id":"resp_test""#, with: #""id":"""#)] {
            try await assertRejected([Self.created, Self.delta("partial", sequence: 1), terminal])
        }
        try await assertRejected([Self.created, Self.completed("", sequence: 1)])
    }

    func testRejectsTruncatedTerminalMessageOutput() async throws {
        for output in [#"{"type":"message"}"#,
                       #"{"type":"message","id":"msg_test","role":"assistant","status":"completed"}"#,
                       #"{"type":"message","id":"msg_test","role":"assistant","content":[{"type":"output_text","text":"partial"}]}"#,
                       #"{"type":"message","id":"msg_test","role":"user","status":"completed","content":[{"type":"output_text","text":"partial"}]}"#,
                       #"{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"partial"}]}"#,
                       #"{"type":"message","id":"msg_test","role":"assistant","status":"completed","content":[{"type":"output_text"}]}"#,
                       #"{"type":"message","id":"msg_test","role":"assistant","status":"completed","content":[{"type":"refusal"}]}"#,
                       #"{"type":"reasoning","id":"rs_test","summary":[]}"#] {
            let terminal = #"{"type":"response.completed","sequence_number":2,"response":{"id":"resp_test","object":"response","status":"completed","error":null,"output":[\#(output)]}}"#
            try await assertRejected([Self.created, Self.delta("partial", sequence: 1), terminal])
        }
    }

    @MainActor
    func testRefusalDeltasAndFinalTextPersistOnceAndClearDraft() async throws {
        for deltas in [true, false] {
            let refusal = "I can’t help with that request."
            var events = [Self.created]
            if deltas { events += [Self.delta("I can’t help ", sequence: 1, refusal: true), Self.delta("with that request.", sequence: 2, refusal: true)] }
            events += [#"{"type":"response.refusal.done","item_id":"msg_test","output_index":0,"content_index":0,"refusal":"I can’t help with that request.","sequence_number":3}"#,
                       Self.completed(refusal, sequence: 4, refusal: true)]
            try await withAppModel(events: events) { model, store in
                model.draft = "Question"
                await model.submit()
                XCTAssertEqual(model.thread?.messages.last?.text, refusal)
                XCTAssertEqual(model.thread?.messages.last?.status, .complete)
                XCTAssertEqual(try store.load().first?.messages.last?.text, refusal)
                XCTAssertTrue(model.draft.isEmpty)
                XCTAssertNil(model.errorMessage)
            }
        }
    }

    @MainActor
    func testInvalidTerminalKeepsPartialTranscriptFailedAndDraftRetryable() async throws {
        for terminal in [#"{"type":"response.completed","sequence_number":2}"#,
                         #"{"type":"response.completed","sequence_number":2,"response":{"id":"resp_test","object":"response","status":"completed","error":null,"output":[{"type":"message"}]}}"#] {
            try await withAppModel(events: [Self.created, Self.delta("partial", sequence: 1), terminal]) { model, store in
                model.draft = "Keep my question"
                await model.submit()
                XCTAssertEqual(model.thread?.messages.last?.text, "partial")
                XCTAssertEqual(model.thread?.messages.last?.status, .failed)
                XCTAssertEqual(try store.load().first?.messages.last?.status, .failed)
                XCTAssertEqual(model.draft, "Keep my question")
                XCTAssertNotNil(model.errorMessage)
                XCTAssertFalse(model.isLoading)
            }
        }
    }

    private func assertRejected(_ events: [String]) async throws {
        let provider = try makeProvider()
        FakePlanURLProtocol.handler = { request in
            (200, request.url?.path == "/v1/models" ? Self.models : Self.sse(events))
        }
        let request = GenerationRequest(id: UUID(), model: .test("text"), messages: [PromptMessage(role: .user, text: "Hi", attachmentIDs: [])], imageData: [:])
        var completed = false
        do {
            for try await event in provider.stream(request) { if case .completed = event { completed = true } }
            XCTFail("Expected stream failure: \(events)")
        } catch { XCTAssertFalse(error.localizedDescription.contains("synthetic-access")) }
        XCTAssertFalse(completed)
    }

    @MainActor
    private func withAppModel(events: [String], check: @MainActor (AppModel, LocalChatStore) async throws -> Void) async throws {
        let provider = try makeProvider()
        FakePlanURLProtocol.handler = { request in
            (200, request.url?.path == "/v1/models" ? Self.models : Self.sse(events))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PetChat.PlanTests.\(UUID())"
        defer { try? FileManager.default.removeItem(at: root); UserDefaults().removePersistentDomain(forName: suite) }
        let attachments = AttachmentStore(root: root)
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try LocalChatStore(container: container, attachments: attachments)
        let coordinator = try ChatCoordinator(providers: [.chatGPT: provider], store: store, attachments: attachments)
        let model = AppModel(coordinator: coordinator, defaults: UserDefaults(suiteName: suite)!)
        try model.select(providerID: .chatGPT, modelID: "text")
        try await check(model, store)
    }

    private static func sse(_ events: [String]) -> Data {
        Data(events.map { "data: " + $0 + "\n\n" }.joined().utf8)
    }

    private static let created = #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_test","object":"response","status":"in_progress","error":null,"output":[]}}"#

    private static func delta(_ text: String, sequence: Int, refusal: Bool = false, outputIndex: Int = 0) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["type": refusal ? "response.refusal.delta" : "response.output_text.delta", "delta": text, "item_id": "msg_test", "output_index": outputIndex, "content_index": 0, "sequence_number": sequence]), encoding: .utf8)!
    }

    private static func completed(_ text: String, sequence: Int, refusal: Bool = false) -> String {
        // Response lifecycle and output fields follow the official Responses streaming examples.
        #"{"type":"response.completed","sequence_number":SEQUENCE,"response":{"id":"resp_test","object":"response","status":"completed","error":null,"incomplete_details":null,"model":"text","output":[{"id":"msg_test","type":"message","role":"assistant","status":"completed","content":[{"type":"TYPE","KEY":TEXT,"annotations":[]}]}]}}"#
            .replacingOccurrences(of: "SEQUENCE", with: String(sequence))
            .replacingOccurrences(of: "TYPE", with: refusal ? "refusal" : "output_text")
            .replacingOccurrences(of: "KEY", with: refusal ? "refusal" : "text")
            .replacingOccurrences(of: "TEXT", with: String(data: try! JSONEncoder().encode(text), encoding: .utf8)!)
    }

    func testUsageLimitEventOffersRecoverableStatus() async throws {
        let provider = try makeProvider()
        FakePlanURLProtocol.handler = { request in
            if request.url?.path == "/v1/models" { return (200, Self.models) }
            return (200, Self.sse([Self.created, #"{"type":"response.failed","sequence_number":1,"response":{"id":"resp_test","object":"response","status":"failed","error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#]))
        }
        let request = GenerationRequest(id: UUID(), model: .test("text"), messages: [PromptMessage(role: .user, text: "Hi", attachmentIDs: [])], imageData: [:])
        do { for try await _ in provider.stream(request) {}; XCTFail("Expected usage limit error") }
        catch { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("limit"), error.localizedDescription) }
    }

    func testRedirectCannotCarryBearerTokenToAnotherHost() async throws {
        let provider = try makeProvider()
        FakePlanURLProtocol.handler = { request in
            if request.url?.host == "api.openai.com" { return (302, Data()) }
            XCTFail("Redirect escaped allowed host")
            return (200, Self.models)
        }
        do { _ = try await provider.availableModels(); XCTFail("Expected rejection") } catch {}
    }

    func testCancelStopsUnderlyingRequest() async throws {
        let provider = try makeProvider()
        let started = expectation(description: "Request started")
        let stopped = expectation(description: "Request stopped")
        FakePlanURLProtocol.expectStop(stopped)
        FakePlanURLProtocol.handler = { request in
            if request.url?.path == "/v1/models" { return (200, Self.models) }
            started.fulfill()
            return nil
        }
        let id = UUID()
        let request = GenerationRequest(id: id, model: .test("text"), messages: [PromptMessage(role: .user, text: "Hi", attachmentIDs: [])], imageData: [:])
        let consumer = Task { for try await _ in provider.stream(request) {} }
        await fulfillment(of: [started], timeout: 2)
        await provider.cancel(id)
        await fulfillment(of: [stopped], timeout: 2)
        do { try await consumer.value; XCTFail("Cancelled generation must terminate with an error") } catch {}
    }

    private func makeProvider() throws -> OpenAIPlanProvider {
        let service = "com.etre.pet-chat.plan-tests.\(UUID())"
        services.append(service)
        let store = KeychainCredentialStore(service: service)
        let credential = ChatGPTCredential(subject: "person", clientID: "oaiapp_pet", hostID: "urn:uuid:test",
            email: nil, idToken: "synthetic-id", accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
            scopes: ["chatgpt.tokens.use.direct"], expiresAt: .distantFuture)
        try store.save(credential, accountID: credential.accountID)
        try store.select(accountID: credential.accountID)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakePlanURLProtocol.self]
        return OpenAIPlanProvider(auth: ChatGPTOAuthClient(store: store), session: URLSession(configuration: config))
    }

    private static let models = Data(#"{"models":[{"slug":"vision","display_name":"Vision","visibility":"list","input_modalities":["text","image"]},{"slug":"text","display_name":"Text","visibility":"list","input_modalities":["text"]},{"slug":"hidden","display_name":"Hidden","visibility":"hidden"}]}"#.utf8)
}

private final class FakePlanURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data)?)?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stopped: XCTestExpectation?
    static func expectStop(_ expectation: XCTestExpectation?) { lock.withLock { stopped = expectation } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let (status, data) = try Self.handler?(request) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: status == 302 ? ["Location": "https://example.com/stolen"] : nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {
        guard request.url?.path == "/v1/responses" else { return }
        let expectation = Self.lock.withLock { let value = Self.stopped; Self.stopped = nil; return value }
        expectation?.fulfill()
    }
}

private extension URLRequest {
    var testBody: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var body = Data(); var buffer = [UInt8](repeating: 0, count: 4_096)
        while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { return body }; body.append(contentsOf: buffer[..<count]) }
    }
}
