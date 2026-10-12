#if DEBUG
import AppKit
import ServiceManagement
import SwiftData

// Only DEBUG test launches use synthetic services and a test-owned temporary directory.
@MainActor
struct UITestFixture {
    let model: AppModel
    let defaults: UserDefaults

    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "PetChat.UI.\(root.lastPathComponent)")!
        let attachments = AttachmentStore(root: root.appendingPathComponent("Attachments"))
        let configuration = ModelConfiguration(url: root.appendingPathComponent("history.store"))
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self, configurations: configuration)
        let store = try LocalChatStore(container: container, attachments: attachments)
        let coordinator = try ChatCoordinator(providers: [.ollama: FixtureProvider(providerID: .ollama),
                                                         .chatGPT: FixtureProvider(providerID: .chatGPT)],
                                              store: store, attachments: attachments)
        var status = SMAppService.Status.notRegistered
        let login = LoginItemController(defaults: defaults, status: { status },
                                        register: { status = .enabled }, unregister: { status = .notRegistered })
        model = AppModel(coordinator: coordinator, defaults: defaults, signIn: {},
                         loginItemController: login, signOut: {})
    }

    static func image() -> Data {
        let image = NSImage(size: NSSize(width: 120, height: 70))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 120, height: 70)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 40, y: 15, width: 40, height: 40)).fill()
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
}

private final class FixtureProvider: ChatProvider, @unchecked Sendable {
    let providerID: ProviderID
    private let lock = NSLock()
    private var hasFailed = false
    init(providerID: ProviderID) { self.providerID = providerID }

    func availableModels() async throws -> [ProviderModel] {
        [ProviderModel(id: "fixture-model", displayName: "Fixture model", supportsImages: true, contextWindowTokens: 4096)]
    }

    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = (request.messages.last?.text ?? "").components(separatedBy: "\n\n").last ?? ""
                    if prompt == "Retry please", lock.withLock({
                        if hasFailed { return false }
                        hasFailed = true
                        return true
                    }) { throw CocoaError(.fileReadUnknown) }
                    if prompt == "Wait please" {
                        continuation.yield(.textDelta("Working slowly"))
                        try await Task.sleep(for: .seconds(120))
                    } else {
                        continuation.yield(.textDelta("Answer \(request.messages.count): "))
                        try await Task.sleep(for: .milliseconds(150))
                        continuation.yield(.textDelta(request.imageData.isEmpty ? prompt : "\(request.imageData.count) image received"))
                    }
                    continuation.yield(.completed)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancel(_ requestID: UUID) async { /* The coordinator ends its stream on Stop. */ }
}
#endif
