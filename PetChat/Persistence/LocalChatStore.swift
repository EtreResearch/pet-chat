import Foundation
import SwiftData

final class LocalChatStore {
    enum Error: Swift.Error { case invalidRecord }

    private let container: ModelContainer
    private let attachments: AttachmentStore
    private let saveContext: (ModelContext) throws -> Void

    init(container: ModelContainer, attachments: AttachmentStore,
         saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        self.container = container
        self.attachments = attachments
        self.saveContext = saveContext
        let context = ModelContext(container)
        try attachments.recoverPending { id in
            try !context.fetch(FetchDescriptor<ChatRecord>(predicate: #Predicate { $0.id == id })).isEmpty
        }
    }

    convenience init(directory: URL? = nil) throws {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PetChat", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("Chats.store"))
        try self.init(container: ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: configuration),
                      attachments: AttachmentStore(root: directory.appendingPathComponent("Attachments")))
    }

    func load() throws -> [ChatThread] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<ChatRecord>(sortBy: [SortDescriptor(\ChatRecord.createdAt)]))
            .map { try $0.thread() }
    }

    func save(_ thread: ChatThread) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let id = thread.id
            let existing = try context.fetch(FetchDescriptor<ChatRecord>(predicate: #Predicate { $0.id == id }))
            existing.forEach(context.delete)
            context.insert(try ChatRecord(thread))
            try saveContext(context)
        } catch {
            throw error
        }
    }

    func delete(threadID: UUID) throws {
        let context = ModelContext(container)
        let staged = try attachments.stageDeletion(threadID: threadID)
        do {
            let existing = try context.fetch(FetchDescriptor<ChatRecord>(predicate: #Predicate { $0.id == threadID }))
            existing.forEach(context.delete)
            try saveContext(context)
        } catch {
            context.rollback()
            if staged { try attachments.restoreDeletion(threadID: threadID) }
            throw error
        }
        try attachments.finishDeletion(threadID: threadID)
    }
}
