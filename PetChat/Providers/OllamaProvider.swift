import Foundation

enum OllamaError: LocalizedError {
    case httpStatus(Int)
    case invalidResponse
    case invalidStream
    case incompleteStream
    case lineTooLong
    case unsupportedImages
    case missingImage

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "Ollama request failed (HTTP \(code)). Check that Ollama is running and the model is installed."
        case .invalidResponse: "Ollama returned an invalid response. Try again."
        case .invalidStream: "Ollama returned an invalid chat stream. Try again."
        case .incompleteStream: "Ollama stopped before completing the answer. Try again."
        case .lineTooLong: "Ollama returned an oversized response. Try again."
        case .unsupportedImages: "This Ollama model does not support images. Select an image-capable model."
        case .missingImage: "The attached image could not be loaded. Add it again before sending."
        }
    }
}

final class OllamaProvider: ChatProvider, @unchecked Sendable {
    let providerID: ProviderID = .ollama
    private let endpoint = URL(string: "http://localhost:11434")!
    private let session: URLSession
    private let noRedirects = NoRedirects()
    private let lock = NSLock()
    private var requests: [UUID: Task<Void, Never>] = [:]
    private let maxJSONBytes = 4 * 1_024 * 1_024
    private let maxLineBytes = 1_024 * 1_024

    init(session: URLSession = .shared) {
        self.session = session
    }

    func availableModels() async throws -> [ProviderModel] {
        let tags: Tags = try await loadJSON(path: "/api/tags", method: "GET", body: nil)
        var models: [ProviderModel] = []
        for tag in tags.models {
            let details = try await modelDetails(tag.name)
            models.append(ProviderModel(
                id: tag.name,
                displayName: tag.name,
                supportsImages: details.capabilities?.contains("vision") == true,
                contextWindowTokens: details.contextWindowTokens
            ))
        }
        return models
    }

    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let currentImages = request.messages.last?.attachmentIDs ?? []
                    guard currentImages.allSatisfy({ request.imageData[$0] != nil }) else { throw OllamaError.missingImage }
                    let details = try await modelDetails(request.modelID)
                    if !currentImages.isEmpty {
                        guard details.capabilities?.contains("vision") == true else { throw OllamaError.unsupportedImages }
                    }

                    let messages: [[String: Any]] = request.messages.enumerated().map { index, message in
                        var item: [String: Any] = [
                            "role": message.role == .user ? "user" : "assistant",
                            "content": message.text
                        ]
                        if index == request.messages.count - 1 && !currentImages.isEmpty {
                            item["images"] = currentImages.compactMap { request.imageData[$0]?.base64EncodedString() }
                        }
                        return item
                    }
                    let body = try JSONSerialization.data(withJSONObject: [
                        "model": request.modelID,
                        "messages": messages,
                        "options": ["num_ctx": details.contextWindowTokens],
                        "stream": true
                    ])
                    var urlRequest = URLRequest(url: endpoint.appending(path: "/api/chat"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.httpBody = body
                    let (bytes, response) = try await session.bytes(for: urlRequest, delegate: noRedirects)
                    try check(response)
                    var line = Data()
                    var sawTerminal = false
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if byte == 10 {
                            try process(line: line, modelID: request.modelID, terminal: &sawTerminal, continuation: continuation)
                            line.removeAll(keepingCapacity: true)
                        } else {
                            guard line.count < maxLineBytes else { throw OllamaError.lineTooLong }
                            line.append(byte)
                        }
                    }
                    if !line.isEmpty {
                        try process(line: line, modelID: request.modelID, terminal: &sawTerminal, continuation: continuation)
                    }
                    try Task.checkCancellation()
                    guard sawTerminal else { throw OllamaError.incompleteStream }
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
        let task = lock.withLock { requests[requestID] }
        task?.cancel()
    }

    private func modelDetails(_ name: String) async throws -> ModelDetails {
        let body = try JSONSerialization.data(withJSONObject: ["model": name])
        return try await loadJSON(path: "/api/show", method: "POST", body: body)
    }

    private func loadJSON<Value: Decodable>(path: String, method: String, body: Data?) async throws -> Value {
        var request = URLRequest(url: endpoint.appending(path: path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (bytes, response) = try await session.bytes(for: request, delegate: noRedirects)
        try check(response)
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxJSONBytes else { throw OllamaError.lineTooLong }
            data.append(byte)
        }
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else { throw OllamaError.invalidResponse }
        return value
    }

    private func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw OllamaError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw OllamaError.httpStatus(response.statusCode) }
    }

    private func process(
        line: Data,
        modelID: String,
        terminal: inout Bool,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) throws {
        let line = line.last == 13 ? line.dropLast() : line[...]
        guard !line.isEmpty else { return }
        guard !terminal, let event = try? JSONDecoder().decode(ChatChunk.self, from: line),
              event.model == modelID, let done = event.done else {
            throw OllamaError.invalidStream
        }
        if let message = event.message {
            guard message.role == "assistant", let content = message.content else { throw OllamaError.invalidStream }
            if !content.isEmpty { continuation.yield(.textDelta(content)) }
        } else if !done {
            throw OllamaError.invalidStream
        }
        if done { terminal = true }
    }
}

private struct Tags: Decodable {
    let models: [Tag]
    struct Tag: Decodable { let name: String }
}

private struct ModelDetails: Decodable {
    let capabilities: [String]?
    let contextWindowTokens: Int

    enum CodingKeys: String, CodingKey {
        case capabilities
        case modelInfo = "model_info"
        case parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities)
        let parameters = try container.decodeIfPresent(String.self, forKey: .parameters) ?? ""
        var configuredContext: Int?
        for line in parameters.split(separator: "\n") {
            let words = line.split(whereSeparator: \.isWhitespace)
            if words.count == 2 && words[0] == "num_ctx" {
                configuredContext = Int(words[1])
                break
            }
        }
        if let info = try? container.nestedContainer(keyedBy: ModelInfoKey.self, forKey: .modelInfo) {
            let modelContext = info.allKeys
                .filter { $0.stringValue.hasSuffix(".context_length") }
                .compactMap { try? info.decode(Int.self, forKey: $0) }
                .first
            let requested = configuredContext.flatMap { $0 > 0 ? $0 : nil } ?? 4_096
            contextWindowTokens = min(modelContext.flatMap { $0 > 0 ? $0 : nil } ?? requested, requested)
        } else {
            contextWindowTokens = configuredContext.flatMap { $0 > 0 ? $0 : nil } ?? 4_096
        }
    }

    private struct ModelInfoKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

private struct ChatChunk: Decodable {
    let model: String?
    let message: Message?
    let done: Bool?

    struct Message: Decodable {
        let role: String?
        let content: String?
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
