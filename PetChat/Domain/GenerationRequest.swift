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

/// The coordinator has already checked the model exists and supports any attached images,
/// and `imageData` holds exactly the final message's attachments.
struct GenerationRequest {
    let id: UUID
    let model: ProviderModel
    let messages: [PromptMessage]
    let imageData: [UUID: Data]
}
