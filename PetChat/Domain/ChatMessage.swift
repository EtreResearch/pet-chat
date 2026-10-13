import Foundation

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case user
        case pet
    }

    enum Status: String, Codable {
        case complete
        case stopped
        case failed
    }

    let id: UUID
    let role: Role
    var text: String
    let attachmentIDs: [UUID]
    var status: Status

    init(id: UUID = UUID(), role: Role, text: String, attachmentIDs: [UUID] = [], status: Status = .complete) {
        self.id = id
        self.role = role
        self.text = text
        self.attachmentIDs = attachmentIDs
        self.status = status
    }
}
