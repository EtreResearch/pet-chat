import Foundation

struct ChatThread: Codable, Identifiable, Equatable {
    let id: UUID
    let providerID: ProviderID
    let modelID: String
    let createdAt: Date
    var messages: [ChatMessage]

    init(id: UUID = UUID(), providerID: ProviderID, modelID: String, createdAt: Date = Date(), messages: [ChatMessage] = []) {
        self.id = id
        self.providerID = providerID
        self.modelID = modelID
        self.createdAt = createdAt
        self.messages = messages
    }
}

extension ChatThread {
    /// The user message the last reply answers, when the chat ends with a user→pet turn.
    var lastAnsweredQuestion: ChatMessage? {
        guard messages.last?.role == .pet, messages.count >= 2,
              messages[messages.count - 2].role == .user else { return nil }
        return messages[messages.count - 2]
    }
}
