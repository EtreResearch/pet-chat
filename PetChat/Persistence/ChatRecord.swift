import Foundation
import SwiftData

@Model
final class ChatRecord {
    var id: UUID
    var providerID: String
    var modelID: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var messages: [MessageRecord]

    init(_ thread: ChatThread) throws {
        id = thread.id
        providerID = thread.providerID.rawValue
        modelID = thread.modelID
        createdAt = thread.createdAt
        messages = try thread.messages.enumerated().map { try MessageRecord($0.element, position: $0.offset) }
    }

    func thread() throws -> ChatThread {
        guard let provider = ProviderID(rawValue: providerID) else { throw LocalChatStore.Error.invalidRecord }
        return try ChatThread(id: id, providerID: provider, modelID: modelID, createdAt: createdAt,
                              messages: messages.sorted { $0.position < $1.position }.map { try $0.message() })
    }
}

@Model
final class MessageRecord {
    var id: UUID
    var position: Int
    var role: String
    var text: String
    var attachmentIDs: [UUID]
    var status: String

    init(_ message: ChatMessage, position: Int) {
        id = message.id
        self.position = position
        role = message.role.rawValue
        text = message.text
        attachmentIDs = message.attachmentIDs
        status = message.status.rawValue
    }

    func message() throws -> ChatMessage {
        guard let role = ChatMessage.Role(rawValue: role), let status = ChatMessage.Status(rawValue: status) else {
            throw LocalChatStore.Error.invalidRecord
        }
        return ChatMessage(id: id, role: role, text: text, attachmentIDs: attachmentIDs, status: status)
    }
}
