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
