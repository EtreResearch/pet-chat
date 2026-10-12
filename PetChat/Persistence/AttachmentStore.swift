import Foundation
import ImageIO

struct AttachmentStore {
    enum Error: LocalizedError, Equatable {
        case missing, invalidImage
        var errorDescription: String? {
            switch self {
            case .missing: "The attached image could not be loaded. Add it again before sending."
            case .invalidImage: "Choose or paste a valid image."
            }
        }
    }

    let root: URL
    private let removeItem: (URL) throws -> Void

    init(root: URL? = nil, removeItem: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PetChat/Attachments", isDirectory: true)
        self.removeItem = removeItem
    }

    func save(_ bytes: Data, threadID: UUID) throws -> UUID {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw Error.invalidImage }
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

    func delete(_ id: UUID, threadID: UUID) throws {
        let path = root.appendingPathComponent(threadID.uuidString).appendingPathComponent(id.uuidString)
        if FileManager.default.fileExists(atPath: path.path) { try removeItem(path) }
    }

    func deleteAll(threadID: UUID) throws {
        let directory = root.appendingPathComponent(threadID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try removeItem(directory)
        }
    }

    private var pendingRoot: URL { root.appendingPathComponent(".pending-deletion", isDirectory: true) }

    func stageDeletion(threadID: UUID) throws -> Bool {
        let directory = root.appendingPathComponent(threadID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        try FileManager.default.createDirectory(at: pendingRoot, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory, to: pendingRoot.appendingPathComponent(threadID.uuidString))
        return true
    }

    func restoreDeletion(threadID: UUID) throws {
        let staged = pendingRoot.appendingPathComponent(threadID.uuidString)
        guard FileManager.default.fileExists(atPath: staged.path) else { return }
        try FileManager.default.moveItem(at: staged, to: root.appendingPathComponent(threadID.uuidString))
    }

    func finishDeletion(threadID: UUID) throws {
        let staged = pendingRoot.appendingPathComponent(threadID.uuidString)
        if FileManager.default.fileExists(atPath: staged.path) {
            try removeItem(staged)
        }
    }

    func recoverPending(threadExists: (UUID) throws -> Bool) throws {
        guard FileManager.default.fileExists(atPath: pendingRoot.path) else { return }
        for directory in try FileManager.default.contentsOfDirectory(at: pendingRoot, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            if try threadExists(id) {
                try restoreDeletion(threadID: id)
            } else {
                try finishDeletion(threadID: id)
            }
        }
    }
}
