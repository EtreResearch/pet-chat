import Foundation
import Security
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
            return (200, Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}\n\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\" there\"}\n\ndata: {\"type\":\"response.completed\"}\n\n".utf8))
        }
        let request = GenerationRequest(id: UUID(), modelID: "vision", messages: [
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

    func testRejectsHiddenModelAndUnsupportedOrMissingImageBeforeInference() async throws {
        let provider = try makeProvider()
        let image = UUID()
        FakePlanURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            return (200, Self.models)
        }
        for (model, data) in [("hidden", Data()), ("text", Data([137,80,78,71,13,10,26,10])), ("vision", Data())] {
            let request = GenerationRequest(id: UUID(), modelID: model, messages: [PromptMessage(role: .user, text: "Look", attachmentIDs: [image])], imageData: data.isEmpty ? [:] : [image: data])
            do { for try await _ in provider.stream(request) {}; XCTFail("Expected rejection") } catch {}
        }
    }

    func testFailedIncompleteAndTruncatedStreamsNeverComplete() async throws {
        for suffix in ["data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"usage_limit\"}}}\n\n",
                       "data: {\"type\":\"response.incomplete\"}\n\n", ""] {
            let provider = try makeProvider()
            FakePlanURLProtocol.handler = { request in
                if request.url?.path == "/v1/models" { return (200, Self.models) }
                return (200, Data(("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n" + suffix).utf8))
            }
            let request = GenerationRequest(id: UUID(), modelID: "text", messages: [PromptMessage(role: .user, text: "Hi", attachmentIDs: [])], imageData: [:])
            var completed = false
            do {
                for try await event in provider.stream(request) { if case .completed = event { completed = true } }
                XCTFail("Expected stream failure")
            } catch { XCTAssertFalse(error.localizedDescription.contains("synthetic-access")) }
            XCTAssertFalse(completed)
        }
    }

    func testUsageLimitEventOffersRecoverableStatus() async throws {
        let provider = try makeProvider()
        FakePlanURLProtocol.handler = { request in
            if request.url?.path == "/v1/models" { return (200, Self.models) }
            return (200, Data("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n\n".utf8))
        }
        let request = GenerationRequest(id: UUID(), modelID: "text", messages: [PromptMessage(role: .user, text: "Hi", attachmentIDs: [])], imageData: [:])
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
        let request = GenerationRequest(id: id, modelID: "text", messages: [PromptMessage(role: .user, text: "Hi", attachmentIDs: [])], imageData: [:])
        let consumer = Task { for try await _ in provider.stream(request) {} }
        await fulfillment(of: [started], timeout: 2)
        await provider.cancel(id)
        await fulfillment(of: [stopped], timeout: 2)
        _ = try? await consumer.value
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
