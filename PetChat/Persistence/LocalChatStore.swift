import Foundation
import SwiftData

final class LocalChatStore {
    enum Error: Swift.Error { case invalidRecord }

    private let container: ModelContainer
    private let attachments: AttachmentStore
    private let saveContext: (ModelContext) throws -> Void

    init(container: ModelContainer, attachments: AttachmentStore = AttachmentStore(),
         saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.container = container
        self.attachments = attachments
        self.saveContext = saveContext
    }

    convenience init() throws {
        try self.init(container: ModelContainer(for: ChatRecord.self, MessageRecord.self))
    }

    func load() throws -> [ChatThread] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<ChatRecord>(sortBy: [SortDescriptor(\ChatRecord.createdAt)]))
            .map { try $0.thread() }
    }

    func save(_ thread: ChatThread) throws {
        let context = ModelContext(container)
        do {
            let id = thread.id
            let existing = try context.fetch(FetchDescriptor<ChatRecord>(predicate: #Predicate { $0.id == id }))
            existing.forEach(context.delete)
            context.insert(try ChatRecord(thread))
            try saveContext(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    func delete(threadID: UUID) throws {
        let context = ModelContext(container)
        do {
            let existing = try context.fetch(FetchDescriptor<ChatRecord>(predicate: #Predicate { $0.id == threadID }))
            existing.forEach(context.delete)
            try saveContext(context)
            try attachments.deleteAll(threadID: threadID)
        } catch {
            context.rollback()
            throw error
        }
    }
}
