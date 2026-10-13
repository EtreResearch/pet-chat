import Foundation
import Observation

@MainActor @Observable
final class ChatCoordinator {
    static let expansionQuestion = "Tell me more about your last answer."
    enum Error: LocalizedError {
        case missingThread, missingProvider, missingModel, busy, emptyMessage, incompleteResponse, stopped, unsupportedImages

        var errorDescription: String? {
            switch self {
            case .missingThread: "This chat no longer exists. Start a new chat."
            case .missingProvider: "This provider is unavailable. Choose another provider."
            case .missingModel: "This model is unavailable. Choose another model."
            case .busy: "Wait for the current answer or press Stop."
            case .emptyMessage: "Enter a question or attach an image."
            case .incompleteResponse: "The answer ended before it completed. Try again."
            case .unsupportedImages: "This model does not support images. Select an image-capable model."
            case .stopped: "Stopped before sending. Your draft is saved."
            }
        }
    }

    private let providers: [ProviderID: any ChatProvider]
    private let store: LocalChatStore
    private let attachments: AttachmentStore
    private(set) var threads: [ChatThread]
    private var activeRequests: [UUID: UUID] = [:]
    private var pendingRequests: Set<UUID> = []

    init(providers: [ProviderID: any ChatProvider], store: LocalChatStore, attachments: AttachmentStore) throws {
        self.providers = providers
        self.store = store
        self.attachments = attachments
        threads = try store.load()
    }

    func attachImage(_ bytes: Data, threadID: UUID) throws -> UUID {
        guard threads.contains(where: { $0.id == threadID }) else { throw Error.missingThread }
        return try attachments.save(bytes, threadID: threadID)
    }

    func imageData(for id: UUID, threadID: UUID) throws -> Data { try attachments.load(id, threadID: threadID) }

    func removeDraftAttachment(_ id: UUID, threadID: UUID) throws {
        guard let thread = threads.first(where: { $0.id == threadID }) else { throw Error.missingThread }
        guard !thread.messages.contains(where: { $0.attachmentIDs.contains(id) }) else { return }
        try attachments.delete(id, threadID: threadID)
    }

    func models(for providerID: ProviderID) async throws -> [ProviderModel] {
        guard let provider = providers[providerID] else { throw Error.missingProvider }
        return try await provider.availableModels()
    }

    func newThread(providerID: ProviderID, modelID: String) throws -> ChatThread {
        guard providers[providerID] != nil else { throw Error.missingProvider }
        guard !modelID.isEmpty else { throw Error.missingModel }
        let thread = ChatThread(providerID: providerID, modelID: modelID)
        try store.save(thread)
        threads.append(thread)
        return thread
    }

    func deleteThread(_ id: UUID) throws {
        if let requestID = activeRequests[id] {
            guard pendingRequests.contains(requestID) else { throw Error.busy }
            activeRequests.removeValue(forKey: id)
        }
        do { try store.delete(threadID: id) }
        catch {
            if let persisted = try? store.load() { threads = persisted }
            else { threads.removeAll { $0.id == id } }
            throw error
        }
        threads.removeAll { $0.id == id }
    }

    func send(text: String, attachmentIDs: [UUID], threadID: UUID) async throws {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { throw Error.missingThread }
        guard activeRequests[threadID] == nil else { throw Error.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachmentIDs.isEmpty else { throw Error.emptyMessage }
        let selected = threads[index]
        guard let provider = providers[selected.providerID] else { throw Error.missingProvider }
        let requestID = UUID()
        activeRequests[threadID] = requestID
        pendingRequests.insert(requestID)
        defer {
            pendingRequests.remove(requestID)
            if activeRequests[threadID] == requestID { activeRequests.removeValue(forKey: threadID) }
        }
        let models = try await provider.availableModels()
        guard activeRequests[threadID] == requestID else { throw Error.stopped }
        guard let thread = threads.first(where: { $0.id == threadID }),
              thread.providerID == selected.providerID, thread.modelID == selected.modelID else { throw Error.missingThread }
        guard let model = models.first(where: { $0.id == thread.modelID }) else { throw Error.missingModel }
        guard attachmentIDs.isEmpty || model.supportsImages else { throw Error.unsupportedImages }
        var seen = Set<UUID>()
        let imageIDs = attachmentIDs.filter { seen.insert($0).inserted }
        let images = try Dictionary(uniqueKeysWithValues: imageIDs.map { ($0, try attachments.load($0, threadID: threadID)) })
        var updated = thread
        if updated.messages.count >= 2,
           updated.messages[updated.messages.count - 2].role == .user,
           updated.messages[updated.messages.count - 2].text == text,
           updated.messages[updated.messages.count - 2].attachmentIDs == imageIDs,
           updated.messages.last?.role == .pet,
           updated.messages.last?.status == .failed {
            updated.messages.removeLast(2)
        }
        let promptText = text == Self.expansionQuestion
            ? "Give more detail about your previous answer.\n\n\(text)"
            : "Answer concisely in one to three sentences or a few short bullets.\n\n\(text)"
        let prompt = ContextBuilder.build(thread: updated, currentText: promptText, currentAttachmentIDs: imageIDs,
                                          contextWindowTokens: model.contextWindowTokens)
        let request = GenerationRequest(id: requestID, model: model, messages: prompt, imageData: images)
        updated.messages.append(ChatMessage(role: .user, text: text, attachmentIDs: imageIDs))
        updated.messages.append(ChatMessage(role: .pet, text: "", status: .failed))
        try save(updated)
        pendingRequests.remove(requestID)
        do {
            var completed = false
            for try await event in provider.stream(request) {
                guard activeRequests[threadID] == request.id else { break }
                switch event {
                case .textDelta(let delta):
                    updated.messages[updated.messages.count - 1].text += delta
                    try save(updated)
                case .completed:
                    completed = true
                }
            }
            if activeRequests[threadID] != request.id { return }
            guard completed else { throw Error.incompleteResponse }
            updated.messages[updated.messages.count - 1].status = .complete
            try save(updated)
        } catch {
            if activeRequests[threadID] != request.id { return }
            // The persisted failed turn remains visible and can be retried from the saved draft.
            throw error
        }
    }

    func stop(threadID: UUID) async throws {
        guard let requestID = activeRequests[threadID],
              let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        var thread = threads[index]
        if pendingRequests.contains(requestID) {
            activeRequests.removeValue(forKey: threadID)
            await providers[thread.providerID]?.cancel(requestID)
            return
        }
        thread.messages[thread.messages.count - 1].status = .stopped
        let saveResult = Result { try save(thread) }
        activeRequests.removeValue(forKey: threadID)
        await providers[thread.providerID]?.cancel(requestID)
        try saveResult.get()
    }

    func stopAll(providerID: ProviderID? = nil) async throws {
        var firstError: Swift.Error?
        let ids = activeRequests.keys.filter { id in
            providerID == nil || threads.first(where: { $0.id == id })?.providerID == providerID
        }
        for id in ids {
            do { try await stop(threadID: id) } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private func save(_ thread: ChatThread) throws {
        try store.save(thread)
        if let index = threads.firstIndex(where: { $0.id == thread.id }) { threads[index] = thread }
    }
}
