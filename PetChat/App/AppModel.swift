import AppKit
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    let coordinator: ChatCoordinator
    private let defaults: UserDefaults
    private let signIn: @MainActor () async throws -> Void
    private(set) var currentThreadID: UUID?
    private(set) var selectedProviderID: ProviderID = .ollama
    private(set) var selectedModelID = ""
    var draft = ""
    var attachmentIDs: [UUID] = []
    var captureRegion: (@MainActor () async throws -> Data?)?
    private(set) var isCapturing = false
    private(set) var isLoading = false
    private var draftContextID = UUID()
    private var activeSubmissionID: UUID?
    private(set) var errorMessage: String?
    private(set) var models: [ProviderModel] = []
    private var modelLoadID: UUID?

    var thread: ChatThread? { coordinator.threads.first { $0.id == currentThreadID } }
    var excludedMessageIDs: Set<UUID> {
        guard let thread else { return [] }
        let contextWindow = models.first { $0.id == thread.modelID }?.contextWindowTokens
        let included = ContextBuilder.includedHistoryIDs(thread: thread, currentText: draft,
                                                         contextWindowTokens: contextWindow)
        return Set(thread.messages.map(\.id)).subtracting(included)
    }

    init(coordinator: ChatCoordinator, auth: ChatGPTOAuthClient = ChatGPTOAuthClient(),
         defaults: UserDefaults = .standard, signIn: (@MainActor () async throws -> Void)? = nil) {
        self.coordinator = coordinator
        self.defaults = defaults
        self.signIn = signIn ?? { _ = try await auth.signIn() }
        if let last = coordinator.threads.last {
            currentThreadID = last.id
            selectedProviderID = last.providerID
            selectedModelID = last.modelID
        } else {
            selectedProviderID = ProviderID(rawValue: defaults.string(forKey: "PetChat.selectedProviderID") ?? "") ?? .ollama
            selectedModelID = defaults.string(forKey: "PetChat.selectedModelID") ?? ""
        }
    }

    func loadModels(for providerID: ProviderID) async {
        let loadID = UUID()
        modelLoadID = loadID
        models = []
        do {
            let available = try await coordinator.models(for: providerID)
            guard modelLoadID == loadID else { return }
            models = available
            errorMessage = nil
        } catch {
            if modelLoadID == loadID { errorMessage = error.localizedDescription }
        }
    }

    func connectChatGPT() async {
        let connectID = UUID()
        modelLoadID = connectID
        models = []
        do {
            try await signIn()
            guard modelLoadID == connectID else { return }
            await loadModels(for: .chatGPT)
        } catch {
            if modelLoadID == connectID { errorMessage = error.localizedDescription }
        }
    }

    func select(providerID: ProviderID, modelID: String) throws {
        guard !isLoading else { throw ChatCoordinator.Error.busy }
        let new = try coordinator.newThread(providerID: providerID, modelID: modelID)
        draftContextID = UUID()
        currentThreadID = new.id
        selectedProviderID = providerID
        selectedModelID = modelID
        defaults.set(providerID.rawValue, forKey: "PetChat.selectedProviderID")
        defaults.set(modelID, forKey: "PetChat.selectedModelID")
        draft = ""
        attachmentIDs = []
        errorMessage = nil
    }

    func newChat() throws { try select(providerID: selectedProviderID, modelID: selectedModelID) }

    func deleteCurrentChat() throws {
        guard !isLoading else { throw ChatCoordinator.Error.busy }
        guard let id = currentThreadID else { return }
        try coordinator.deleteThread(id)
        draftContextID = UUID()
        currentThreadID = coordinator.threads.last?.id
        if let thread { selectedProviderID = thread.providerID; selectedModelID = thread.modelID }
        draft = ""
        attachmentIDs = []
        errorMessage = nil
    }

    func attachImage(_ bytes: Data) throws {
        guard let id = currentThreadID else { throw ChatCoordinator.Error.missingThread }
        guard !isLoading else { throw ChatCoordinator.Error.busy }
        attachmentIDs.append(try coordinator.attachImage(bytes, threadID: id))
    }

    func imageData(for id: UUID) -> Data? {
        guard let threadID = currentThreadID else { return nil }
        return try? coordinator.imageData(for: id, threadID: threadID)
    }

    func pasteImage(from pasteboard: NSPasteboard = .general) throws {
        if let png = pasteboard.data(forType: .png) { try attachImage(png); return }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw AttachmentStore.Error.invalidImage }
        try attachImage(png)
    }

    func removeAttachment(_ id: UUID) throws {
        guard let threadID = currentThreadID, !isLoading else { throw ChatCoordinator.Error.busy }
        try coordinator.removeDraftAttachment(id, threadID: threadID)
        attachmentIDs.removeAll { $0 == id }
    }

    func captureImage(using capture: (@MainActor () async throws -> Data?)? = nil) async {
        guard let threadID = currentThreadID, !isLoading, !isCapturing,
              let capture = capture ?? captureRegion else { return }
        let contextID = draftContextID
        isCapturing = true
        defer { isCapturing = false }
        do {
            let bytes = try await capture()
            guard draftContextID == contextID, currentThreadID == threadID else { return }
            if let bytes { try attachImage(bytes) }
        } catch {
            if draftContextID == contextID, currentThreadID == threadID { report(error) }
        }
    }

    func submit() async {
        guard let id = currentThreadID, !isLoading else { return }
        let text = draft
        let images = attachmentIDs
        let submissionID = UUID()
        activeSubmissionID = submissionID
        isLoading = true
        errorMessage = nil
        defer {
            if activeSubmissionID == submissionID {
                activeSubmissionID = nil
                isLoading = false
            }
        }
        do {
            try await coordinator.send(text: text, attachmentIDs: images, threadID: id)
            if activeSubmissionID == submissionID, currentThreadID == id,
               thread?.messages.last?.status == .complete {
                if draft == text { draft = "" }
                attachmentIDs.removeAll { images.contains($0) }
            }
        } catch {
            if activeSubmissionID == submissionID { errorMessage = error.localizedDescription }
        }
    }

    func retry() async { await submit() }

    func tellMeMore() async {
        guard draft.isEmpty, attachmentIDs.isEmpty,
              thread?.messages.last?.role == .pet, thread?.messages.last?.status == .complete else { return }
        draft = ChatCoordinator.expansionQuestion
        await submit()
    }

    func stop() async {
        guard let id = currentThreadID else { return }
        let submissionID = activeSubmissionID
        do { try await coordinator.stop(threadID: id) }
        catch {
            if activeSubmissionID == submissionID || activeSubmissionID == nil {
                errorMessage = error.localizedDescription
            }
        }
        if activeSubmissionID == submissionID {
            activeSubmissionID = nil
            isLoading = false
        }
    }

    func report(_ error: Error) { errorMessage = error.localizedDescription }
}
