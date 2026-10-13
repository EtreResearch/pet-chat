import Foundation

enum OllamaError: LocalizedError {
    case httpStatus(Int)
    case invalidResponse
    case invalidStream
    case incompleteStream
    case lineTooLong

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "Ollama request failed (HTTP \(code)). Check that Ollama is running and the model is installed."
        case .invalidResponse: "Ollama returned an invalid response. Try again."
        case .invalidStream: "Ollama returned an invalid chat stream. Try again."
        case .incompleteStream: "Ollama stopped before completing the answer. Try again."
        case .lineTooLong: "Ollama returned an oversized response. Try again."
        }
    }
}

final class OllamaProvider: ChatProvider, @unchecked Sendable {
    private let endpoint = URL(string: "http://localhost:11434")!
    private let session: URLSession
    private let noRedirects = NoRedirects()
    private let tasks = GenerationTasks()
    private let maxJSONBytes = 4 * 1_024 * 1_024
    private let maxLineBytes = 1_024 * 1_024

    init(session: URLSession = .shared) {
        self.session = session
    }

    func availableModels() async throws -> [ProviderModel] {
        let tags: Tags = try await loadJSON(path: "/api/tags", method: "GET", body: nil)
        var models: [ProviderModel] = []
        // ponytail: one /api/show per installed model on every discovery; cache per model if users install many.
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
        tasks.stream(id: request.id) { [self] continuation in
            let currentImages = request.messages.last?.attachmentIDs ?? []
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
                "model": request.model.id,
                "messages": messages,
                "options": ["num_ctx": request.model.contextWindowTokens ?? ModelDetails.defaultContext],
                "stream": true
            ])
            var urlRequest = URLRequest(url: endpoint.appending(path: "/api/chat"))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = body
            let (bytes, response) = try await session.bytes(for: urlRequest, delegate: noRedirects)
            try check(response)
            var sawTerminal = false
            _ = try await bytes.forEachLine(maxBytes: maxLineBytes, tooLong: OllamaError.lineTooLong) { line in
                try process(line: line, modelID: request.model.id, terminal: &sawTerminal, continuation: continuation)
                return false
            }
            try Task.checkCancellation()
            guard sawTerminal else { throw OllamaError.incompleteStream }
        }
    }

    func cancel(_ requestID: UUID) async { tasks.cancel(requestID) }

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
    static let defaultContext = 4_096
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
        let requested = configuredContext.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultContext
        let modelContext = (try? container.nestedContainer(keyedBy: ModelInfoKey.self, forKey: .modelInfo)).flatMap { info in
            info.allKeys
                .filter { $0.stringValue.hasSuffix(".context_length") }
                .compactMap { try? info.decode(Int.self, forKey: $0) }
                .first { $0 > 0 }
        }
        contextWindowTokens = min(modelContext ?? requested, requested)
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
