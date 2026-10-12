import Foundation

final class OpenAIPlanProvider: ChatProvider, @unchecked Sendable {
    let providerID: ProviderID = .chatGPT
    private let auth: ChatGPTOAuthClient
    private let session: URLSession
    private let noRedirects = PlanNoRedirects()
    private let lock = NSLock()
    private var requests: [UUID: Task<Void, Never>] = [:]
    private let endpoint = URL(string: "https://api.openai.com/v1")!
    private let maxJSONBytes = 1_000_000
    private let maxLineBytes = 1_000_000

    init(auth: ChatGPTOAuthClient = ChatGPTOAuthClient(), session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    func availableModels() async throws -> [ProviderModel] {
        let credential = try await auth.credential()
        return try await models(accessToken: credential.accessToken)
    }

    private func models(accessToken: String) async throws -> [ProviderModel] {
        var request = URLRequest(url: endpoint.appending(path: "models"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request, delegate: noRedirects)
        try check(response, expected: request.url!)
        guard data.count <= maxJSONBytes,
              let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data) else {
            throw ChatGPTError.invalidResponse
        }
        return catalog.models.filter { $0.visibility == "list" && !$0.slug.isEmpty && !$0.displayName.isEmpty }.map {
            // shortcut: absent image metadata means text-only; verify per-model capabilities if the catalog omits modalities.
            ProviderModel(id: $0.slug, displayName: $0.displayName,
                          supportsImages: ($0.inputModalities ?? $0.supportedInputModalities)?.contains("image") == true,
                          contextWindowTokens: $0.contextWindow)
        }
    }

    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let credential = try await auth.credential()
                    let available = try await models(accessToken: credential.accessToken)
                    guard let model = available.first(where: { $0.id == request.modelID }) else {
                        throw ChatGPTError.unavailableModel
                    }
                    let imageIDs = request.messages.last?.role == .user ? request.messages.last?.attachmentIDs ?? [] : []
                    guard imageIDs.allSatisfy({ request.imageData[$0] != nil }) else { throw ChatGPTError.missingImage }
                    guard imageIDs.isEmpty || model.supportsImages else { throw ChatGPTError.unsupportedImages }
                    let input: [[String: Any]] = try request.messages.enumerated().map { index, message in
                        let role = message.role == .user ? "user" : "assistant"
                        guard index == request.messages.count - 1, !imageIDs.isEmpty else {
                            return ["role": role, "content": message.text]
                        }
                        var content: [[String: Any]] = [["type": "input_text", "text": message.text]]
                        for id in imageIDs {
                            guard let data = request.imageData[id] else { throw ChatGPTError.missingImage }
                            guard let mime = Self.mimeType(data) else { throw ChatGPTError.unsupportedImages }
                            content.append(["type": "input_image", "image_url": "data:\(mime);base64,\(data.base64EncodedString())"])
                        }
                        return ["role": role, "content": content]
                    }
                    let body = try JSONSerialization.data(withJSONObject: [
                        "model": request.modelID, "input": input, "store": false, "stream": true
                    ])
                    var urlRequest = URLRequest(url: endpoint.appending(path: "responses"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.httpBody = body
                    let (bytes, response) = try await session.bytes(for: urlRequest, delegate: noRedirects)
                    try check(response, expected: urlRequest.url!)
                    var line = Data()
                    var eventData = Data()
                    var completed = false
                    var state = StreamState()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if byte == 10 {
                            if try process(line: line, eventData: &eventData, state: &state, continuation: continuation) {
                                completed = true
                                break
                            }
                            line.removeAll(keepingCapacity: true)
                        } else {
                            guard line.count < maxLineBytes else { throw ChatGPTError.invalidResponse }
                            line.append(byte)
                        }
                    }
                    if !completed {
                        if !line.isEmpty, try process(line: line, eventData: &eventData, state: &state, continuation: continuation) { completed = true }
                        else if !eventData.isEmpty { completed = try dispatch(eventData, state: &state, continuation: continuation) }
                    }
                    try Task.checkCancellation()
                    guard completed else { throw ChatGPTError.incompleteResponse }
                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            lock.withLock { requests[request.id] = task }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                _ = self?.lock.withLock { self?.requests.removeValue(forKey: request.id) }
            }
        }
    }

    func cancel(_ requestID: UUID) async {
        lock.withLock { requests[requestID] }?.cancel()
    }

    private func check(_ response: URLResponse, expected: URL) throws {
        guard expected.scheme == "https", expected.host == "api.openai.com", expected.port == nil,
              ["/v1/models", "/v1/responses"].contains(expected.path),
              let response = response as? HTTPURLResponse, response.url == expected else {
            throw ChatGPTError.invalidResponse
        }
        guard response.statusCode == 200 else { throw ChatGPTError.requestFailed(response.statusCode) }
    }

    private func process(line: Data, eventData: inout Data, state: inout StreamState,
                         continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) throws -> Bool {
        let line = line.last == 13 ? line.dropLast() : line[...]
        if line.isEmpty {
            guard !eventData.isEmpty else { return false }
            defer { eventData.removeAll(keepingCapacity: true) }
            return try dispatch(eventData, state: &state, continuation: continuation)
        }
        if line.starts(with: Data("data: ".utf8)) {
            guard eventData.count + line.count <= maxJSONBytes else { throw ChatGPTError.invalidResponse }
            if !eventData.isEmpty { eventData.append(10) }
            eventData.append(line.dropFirst(6))
        } else if line.starts(with: Data("data:".utf8)) {
            guard eventData.count + line.count <= maxJSONBytes else { throw ChatGPTError.invalidResponse }
            if !eventData.isEmpty { eventData.append(10) }
            eventData.append(line.dropFirst(5))
        }
        return false
    }

    private func dispatch(_ data: Data, state: inout StreamState,
                          continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) throws -> Bool {
        guard let event = try? JSONDecoder().decode(StreamEvent.self, from: data) else {
            throw ChatGPTError.invalidResponse
        }
        guard event.sequenceNumber >= 0, event.sequenceNumber > state.lastSequence else {
            throw ChatGPTError.invalidResponse
        }
        state.lastSequence = event.sequenceNumber
        if let response = event.response {
            guard let id = response.id, !id.isEmpty, response.object == "response",
                  state.responseID == nil || state.responseID == id else { throw ChatGPTError.invalidResponse }
            state.responseID = id
        }
        switch event.type {
        case "response.created":
            guard event.response?.status == "in_progress" else { throw ChatGPTError.invalidResponse }
            return false
        case "response.output_text.delta":
            guard let delta = event.delta else { throw ChatGPTError.invalidResponse }
            if !delta.isEmpty { state.hasText = true; continuation.yield(.textDelta(delta)) }
            return false
        case "response.refusal.delta", "response.refusal.done":
            guard let itemID = event.itemID, !itemID.isEmpty,
                  let outputIndex = event.outputIndex, outputIndex >= 0,
                  let contentIndex = event.contentIndex, contentIndex >= 0 else { throw ChatGPTError.invalidResponse }
            let key = RefusalKey(itemID: itemID, outputIndex: outputIndex, contentIndex: contentIndex)
            let previous = state.refusals[key, default: ""]
            let delta: String
            if event.type == "response.refusal.delta" {
                guard let text = event.delta else { throw ChatGPTError.invalidResponse }
                delta = text
                state.refusals[key] = previous + text
            } else {
                guard let text = event.refusal, text.hasPrefix(previous) else { throw ChatGPTError.invalidResponse }
                delta = String(text.dropFirst(previous.count))
                state.refusals[key] = text
            }
            if !delta.isEmpty { state.hasText = true; continuation.yield(.textDelta(delta)) }
            return false
        case "response.completed":
            guard let response = event.response, response.status == "completed", response.error == nil,
                  let output = response.output, !output.isEmpty, state.hasText else { throw ChatGPTError.invalidResponse }
            return true
        case "response.failed":
            if let code = event.response?.error?.code,
               ["subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable"].contains(code) {
                throw ChatGPTError.usageLimit
            }
            throw ChatGPTError.incompleteResponse
        case "response.incomplete", "error": throw ChatGPTError.incompleteResponse
        default: return false
        }
    }

    private static func mimeType(_ data: Data) -> String? {
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return "image/png" }
        if data.starts(with: [255, 216, 255]) { return "image/jpeg" }
        if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) { return "image/gif" }
        if data.count >= 12, data.starts(with: Data("RIFF".utf8)), data[8..<12] == Data("WEBP".utf8) { return "image/webp" }
        return nil
    }
}

private struct ModelCatalog: Decodable { let models: [PlanModel] }
private struct PlanModel: Decodable {
    let slug: String
    let displayName: String
    let visibility: String
    let inputModalities: [String]?
    let supportedInputModalities: [String]?
    let contextWindow: Int?
    enum CodingKeys: String, CodingKey {
        case slug, visibility
        case displayName = "display_name"
        case inputModalities = "input_modalities"
        case supportedInputModalities = "supported_input_modalities"
        case contextWindow = "context_window"
    }
}
private struct StreamState {
    var lastSequence = -1
    var responseID: String?
    var hasText = false
    var refusals: [RefusalKey: String] = [:]
}

private struct RefusalKey: Hashable {
    let itemID: String
    let outputIndex: Int
    let contentIndex: Int
}

private struct StreamEvent: Decodable {
    let type: String
    let sequenceNumber: Int
    let delta: String?
    let refusal: String?
    let itemID: String?
    let outputIndex: Int?
    let contentIndex: Int?
    let response: Response?
    enum CodingKeys: String, CodingKey {
        case type, delta, refusal, response
        case sequenceNumber = "sequence_number"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
    }
    struct Response: Decodable {
        let id: String?
        let object: String?
        let status: String?
        let output: [Output]?
        let error: Failure?
        struct Output: Decodable { let type: String }
        struct Failure: Decodable { let code: String? }
    }
}

private final class PlanNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
