import Foundation

enum GenerationEvent {
    case textDelta(String)
    case completed
}

protocol ChatProvider: Sendable {
    func availableModels() async throws -> [ProviderModel]
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
    func cancel(_ requestID: UUID) async
}

/// Runs each generation in a task that `cancel(_:)` can stop by request ID.
final class GenerationTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// `body` streams deltas and returns only after the provider confirmed completion.
    func stream(id: UUID, _ body: @escaping @Sendable (AsyncThrowingStream<GenerationEvent, Error>.Continuation) async throws -> Void)
        -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            lock.withLock { tasks[id] = task }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                _ = self?.lock.withLock { self?.tasks.removeValue(forKey: id) }
            }
        }
    }

    func cancel(_ id: UUID) { lock.withLock { tasks[id] }?.cancel() }
}

extension URLSession.AsyncBytes {
    /// Calls `handle` with each line (LF-separated, trailing CR removed) until it returns true.
    func forEachLine(maxBytes: Int, tooLong: Error, _ handle: (Data) throws -> Bool) async throws -> Bool {
        func stripped(_ line: Data) -> Data { line.last == 13 ? line.dropLast() : line }
        var line = Data()
        for try await byte in self {
            try Task.checkCancellation()
            if byte == 10 {
                if try handle(stripped(line)) { return true }
                line.removeAll(keepingCapacity: true)
            } else {
                guard line.count < maxBytes else { throw tooLong }
                line.append(byte)
            }
        }
        return line.isEmpty ? false : try handle(stripped(line))
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
