import Foundation

struct PromptMessage: Equatable {
    enum Role {
        case user
        case assistant
    }

    let role: Role
    let text: String
    let attachmentIDs: [UUID]
}

struct GenerationRequest {
    let id: UUID
    let modelID: String
    let messages: [PromptMessage]
    let imageData: [UUID: Data]

    init(id: UUID, modelID: String, messages: [PromptMessage], imageData: [UUID: Data]) {
        self.id = id
        self.modelID = modelID
        self.messages = messages
        let currentIDs = Set(messages.last?.attachmentIDs ?? [])
        self.imageData = imageData.filter { currentIDs.contains($0.key) }
    }
}
