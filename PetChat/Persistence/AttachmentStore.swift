import Foundation

struct AttachmentStore {
    enum Error: Swift.Error, Equatable { case missing }

    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PetChat/Attachments", isDirectory: true)
    }

    func save(_ bytes: Data, threadID: UUID) throws -> UUID {
        let id = UUID()
        let directory = root.appendingPathComponent(threadID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent(id.uuidString), options: .atomic)
        return id
    }

    func load(_ id: UUID, threadID: UUID) throws -> Data {
        let path = root.appendingPathComponent(threadID.uuidString, isDirectory: true)
            .appendingPathComponent(id.uuidString)
        guard FileManager.default.fileExists(atPath: path.path) else { throw Error.missing }
        return try Data(contentsOf: path)
    }

    func deleteAll(threadID: UUID) throws {
        let directory = root.appendingPathComponent(threadID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
