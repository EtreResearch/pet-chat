import Foundation
import XCTest
@testable import PetChat

final class OllamaProviderTests: XCTestCase {
    override func tearDown() {
        MockOllamaURLProtocol.handler = nil
        MockOllamaURLProtocol.expectStop(nil)
        MockOllamaURLProtocol.redirectLocation = nil
        super.tearDown()
    }

    func testListsInstalledModels() async throws {
        MockOllamaURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/tags":
                return (200, #"{"models":[{"name":"vision:latest"},{"name":"text:latest"}]}"#.data(using: .utf8)!)
            case "/api/show":
                let model = (try? JSONSerialization.jsonObject(with: request.testBody) as? [String: String])?["model"]
                if model == "vision:latest" {
                    return (200, #"{"capabilities":["completion","vision"],"parameters":"temperature 0.7\nnum_ctx 2048","model_info":{"gemma.context_length":8192,"general.architecture":"gemma"}}"#.data(using: .utf8)!)
                }
                return (200, #"{"capabilities":["completion"],"model_info":{"llama.context_length":8192}}"#.data(using: .utf8)!)
            default:
                XCTFail("Unexpected request: \(request)")
                return (404, Data())
            }
        }

        let models = try await provider().availableModels()
        XCTAssertEqual(models, [
            ProviderModel(id: "vision:latest", displayName: "vision:latest", supportsImages: true, contextWindowTokens: 2048),
            ProviderModel(id: "text:latest", displayName: "text:latest", supportsImages: false, contextWindowTokens: 4096)
        ])
    }

    func testChatContextOptionMatchesDiscoveredConfiguredAndDefaultWindows() async throws {
        let cases: [(name: String, details: String, context: Int)] = [
            ("configured", #"{"capabilities":["completion"],"parameters":"num_ctx 2048","model_info":{"llama.context_length":8192}}"#, 2048),
            ("default", #"{"capabilities":["completion"],"model_info":{"llama.context_length":8192}}"#, 4096),
            ("small", #"{"capabilities":["completion"],"model_info":{"llama.context_length":2048}}"#, 2048)
        ]
        for item in cases {
            MockOllamaURLProtocol.handler = { request in
                switch request.url?.path {
                case "/api/tags":
                    return (200, Data("{\"models\":[{\"name\":\"\(item.name)\"}]}".utf8))
                case "/api/show":
                    return (200, Data(item.details.utf8))
                case "/api/chat":
                    guard let body = try? JSONSerialization.jsonObject(with: request.testBody) as? [String: Any],
                          let options = body["options"] as? [String: Int] else {
                        XCTFail("Missing chat options")
                        return (400, Data())
                    }
                    XCTAssertEqual(options["num_ctx"], item.context)
                    return (200, Data("{\"model\":\"\(item.name)\",\"done\":true}\n".utf8))
                default:
                    XCTFail("Unexpected request: \(request)")
                    return (404, Data())
                }
            }
            let provider = provider()
            let models = try await provider.availableModels()
            XCTAssertEqual(models.first?.contextWindowTokens, item.context)
            let request = GenerationRequest(id: UUID(), modelID: item.name, messages: [
                PromptMessage(role: .user, text: "Hi", attachmentIDs: [])
            ], imageData: [:])
            var completed = false
            for try await event in provider.stream(request) {
                if case .completed = event { completed = true }
            }
            XCTAssertTrue(completed)
        }
    }

    func testDoesNotFollowRedirectOutsideLocalOllama() async throws {
        MockOllamaURLProtocol.redirectLocation = "http://example.com/api/tags"
        MockOllamaURLProtocol.handler = { request in
            if request.url?.host == "localhost" { return (302, Data()) }
            XCTFail("Redirect escaped localhost")
            return (200, #"{"models":[]}"#.data(using: .utf8)!)
        }
        do {
            _ = try await provider().availableModels()
            XCTFail("Expected redirect rejection")
        } catch {
            // A redirect response is not a successful local discovery response.
        }
    }

    func testRejectsImagesForTextOnlyModel() async throws {
        let imageID = UUID()
        MockOllamaURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/show")
            return (200, #"{"capabilities":["completion"]}"#.data(using: .utf8)!)
        }
        let request = GenerationRequest(id: UUID(), modelID: "text:latest", messages: [
            PromptMessage(role: .user, text: "Look", attachmentIDs: [imageID])
        ], imageData: [imageID: Data([1, 2, 3])])

        do {
            for try await _ in provider().stream(request) { XCTFail("Should not emit") }
            XCTFail("Expected unsupported image error")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("image"))
        }
    }

    func testRejectsImagesWhenCapabilityIsUnknown() async throws {
        let imageID = UUID()
        MockOllamaURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/show")
            return (200, #"{"model_info":{}}"#.data(using: .utf8)!)
        }
        let request = GenerationRequest(id: UUID(), modelID: "unknown", messages: [
            PromptMessage(role: .user, text: "Look", attachmentIDs: [imageID])
        ], imageData: [imageID: Data([1])])
        do {
            for try await _ in provider().stream(request) { XCTFail("Should not emit") }
            XCTFail("Expected unsupported image error")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("image"))
        }
    }

    func testSendsImagesOnlyOnCurrentPromptForVisionModel() async throws {
        let oldID = UUID()
        let currentID = UUID()
        MockOllamaURLProtocol.handler = { request in
            if request.url?.path == "/api/show" {
                return (200, #"{"capabilities":["completion","vision"]}"#.data(using: .utf8)!)
            }
            XCTAssertEqual(request.url?.path, "/api/chat")
            guard let body = try? JSONSerialization.jsonObject(with: request.testBody) as? [String: Any],
                  let messages = body["messages"] as? [[String: Any]] else {
                XCTFail("Invalid chat request body")
                return (400, Data())
            }
            XCTAssertNil(messages[0]["images"])
            XCTAssertEqual(messages[1]["images"] as? [String], [Data([1, 2, 3]).base64EncodedString()])
            XCTAssertEqual((body["options"] as? [String: Int])?["num_ctx"], 4096)
            return (200, Data((#"{"model":"vision","message":{"role":"assistant","content":""},"done":true}"# + "\n").utf8))
        }
        let request = GenerationRequest(id: UUID(), modelID: "vision", messages: [
            PromptMessage(role: .user, text: "Old", attachmentIDs: [oldID]),
            PromptMessage(role: .user, text: "Look", attachmentIDs: [currentID])
        ], imageData: [oldID: Data([9]), currentID: Data([1, 2, 3])])
        var completed = false
        for try await event in provider().stream(request) {
            if case .completed = event { completed = true }
        }
        XCTAssertTrue(completed)
    }

    func testEmitsOrderedDeltasAndCompletion() async throws {
        MockOllamaURLProtocol.handler = { request in
            if request.url?.path == "/api/show" {
                return (200, Data("{}".utf8))
            }
            XCTAssertEqual(request.url?.host, "localhost")
            XCTAssertEqual(request.url?.port, 11434)
            XCTAssertEqual(request.url?.path, "/api/chat")
            guard let body = try? JSONSerialization.jsonObject(with: request.testBody) as? [String: Any] else {
                XCTFail("Invalid chat request body")
                return (400, Data())
            }
            XCTAssertEqual(body["model"] as? String, "text:latest")
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertEqual((body["options"] as? [String: Int])?["num_ctx"], 4096)
            guard let messages = body["messages"] as? [[String: Any]] else {
                XCTFail("Missing chat messages")
                return (400, Data())
            }
            XCTAssertEqual(messages.map { $0["content"] as? String }, ["Hi", "Hello", "Again"])
            XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
            XCTAssertNil(messages.last?["images"])
            return (200, Data((
                #"{"model":"text:latest","message":{"role":"assistant","content":"A"},"done":false}"# + "\n" +
                #"{"model":"text:latest","message":{"role":"assistant","content":"B"},"done":false}"# + "\n" +
                #"{"model":"text:latest","message":{"role":"assistant","content":""},"done":true}"# + "\n"
            ).utf8))
        }
        let request = GenerationRequest(id: UUID(), modelID: "text:latest", messages: [
            PromptMessage(role: .user, text: "Hi", attachmentIDs: []),
            PromptMessage(role: .assistant, text: "Hello", attachmentIDs: []),
            PromptMessage(role: .user, text: "Again", attachmentIDs: [])
        ], imageData: [:])
        var events: [String] = []
        for try await event in provider().stream(request) {
            switch event {
            case .textDelta(let text): events.append(text)
            case .completed: events.append("completed")
            }
        }
        XCTAssertEqual(events, ["A", "B", "completed"])
    }

    func testCancelStopsUnderlyingRequest() async throws {
        let started = expectation(description: "URLProtocol started")
        let stopped = expectation(description: "URLProtocol stopped")
        MockOllamaURLProtocol.expectStop(stopped)
        MockOllamaURLProtocol.handler = { request in
            if request.url?.path == "/api/show" {
                return (200, Data("{}".utf8))
            }
            XCTAssertEqual(request.url?.path, "/api/chat")
            started.fulfill()
            return nil // Leave the request in flight until cancellation.
        }
        let provider = provider()
        let id = UUID()
        let request = GenerationRequest(id: id, modelID: "text:latest", messages: [
            PromptMessage(role: .user, text: "Hi", attachmentIDs: [])
        ], imageData: [:])
        let consumer = Task {
            for try await _ in provider.stream(request) {}
        }
        await fulfillment(of: [started], timeout: 2)
        await provider.cancel(id)
        await fulfillment(of: [stopped], timeout: 2)
        _ = try? await consumer.value
    }

    private func provider() -> OllamaProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOllamaURLProtocol.self]
        return OllamaProvider(session: URLSession(configuration: configuration))
    }
}

final class MockOllamaURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data)?)?
    private static let stopLock = NSLock()
    nonisolated(unsafe) private static var stopped: XCTestExpectation?
    nonisolated(unsafe) static var redirectLocation: String?

    static func expectStop(_ expectation: XCTestExpectation?) {
        stopLock.withLock { stopped = expectation }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let result = Self.handler?(request) else { return }
        let headers = Self.redirectLocation.map { ["Location": $0] }
        let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: headers)!
        if result.0 == 302, let location = Self.redirectLocation, let url = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        let expectation = Self.stopLock.withLock {
            let expectation = Self.stopped
            Self.stopped = nil
            return expectation
        }
        expectation?.fulfill()
    }
}

private extension URLRequest {
    var testBody: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return body }
            body.append(contentsOf: buffer[..<count])
        }
    }
}
