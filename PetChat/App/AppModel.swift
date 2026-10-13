import AppKit
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    let coordinator: ChatCoordinator
    let loginItemController: LoginItemController
    private let defaults: UserDefaults
    private let auth: ChatGPTOAuthClient
    private var isShuttingDown = false
    private var captureTask: Task<Data?, Error>?
    private let signOut: @MainActor () async throws -> Void
    private let signIn: @MainActor () async throws -> Void
    private(set) var currentThreadID: UUID?
    private(set) var selectedProviderID: ProviderID = .ollama
    private(set) var selectedModelID = ""
    var textSize: Double { didSet { defaults.set(textSize, forKey: "PetChat.textSize") } }
    var draft = ""
    var attachmentIDs: [UUID] = []
    var captureRegion: (@MainActor () async throws -> Data?)?
    private(set) var isCapturing = false
    private(set) var isLoading = false
    private var draftContextID = UUID()
    private var activeSubmissionID: UUID?
    private(set) var errorMessage: String?
    private(set) var canRetrySubmission = false
    private(set) var models: [ProviderModel] = []
    private var modelLoadID: UUID?
    private var modelLoadProviderID: ProviderID?
    private var modelLoadTask: Task<[ProviderModel], Error>?
    private var submissionTask: Task<Void, Error>?
    private var isConnectingChatGPT = false

    var thread: ChatThread? { coordinator.threads.first { $0.id == currentThreadID } }
    var excludedMessageIDs: Set<UUID> {
        guard let thread else { return [] }
        let contextWindow = models.first { $0.id == thread.modelID }?.contextWindowTokens
        let included = ContextBuilder.includedHistoryIDs(thread: thread, currentText: draft,
                                                         contextWindowTokens: contextWindow)
        return Set(thread.messages.map(\.id)).subtracting(included)
    }

    init(coordinator: ChatCoordinator, auth: ChatGPTOAuthClient = ChatGPTOAuthClient(),
         defaults: UserDefaults = .standard, signIn: (@MainActor () async throws -> Void)? = nil,
         loginItemController: LoginItemController? = nil, signOut: (@MainActor () async throws -> Void)? = nil) {
        self.coordinator = coordinator
        self.auth = auth
        self.defaults = defaults
        textSize = defaults.double(forKey: "PetChat.textSize") == 17 ? 17 : 13
        self.loginItemController = loginItemController ?? LoginItemController(defaults: defaults)
        self.signIn = signIn ?? { _ = try await auth.signIn() }
        self.signOut = signOut ?? { try await auth.signOut() }
        if let last = coordinator.threads.last {
            currentThreadID = last.id
            selectedProviderID = last.providerID
            selectedModelID = last.modelID
            if last.messages.last?.role == .pet, last.messages.last?.status == .failed,
               let question = last.messages.dropLast().last, question.role == .user {
                draft = question.text
                attachmentIDs = question.attachmentIDs
                errorMessage = ChatCoordinator.Error.incompleteResponse.localizedDescription
                canRetrySubmission = true
            }
        } else {
            selectedProviderID = ProviderID(rawValue: defaults.string(forKey: "PetChat.selectedProviderID") ?? "") ?? .ollama
            selectedModelID = defaults.string(forKey: "PetChat.selectedModelID") ?? ""
        }
    }

    func loadModels(for providerID: ProviderID) async {
        guard !isShuttingDown else { return }
        let loadID = UUID()
        modelLoadTask?.cancel()
        modelLoadID = loadID
        modelLoadProviderID = providerID
        let task = Task { try await coordinator.models(for: providerID) }
        modelLoadTask = task
        defer {
            if modelLoadID == loadID { modelLoadTask = nil; modelLoadProviderID = nil }
        }
        models = []
        do {
            let available = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard modelLoadID == loadID else { return }
            models = available
            if !canRetrySubmission { errorMessage = nil }
        } catch {
            if modelLoadID == loadID { report(error) }
        }
    }

    func connectChatGPT() async {
        guard !isShuttingDown, !isConnectingChatGPT else { return }
        isConnectingChatGPT = true
        defer { isConnectingChatGPT = false }
        let connectID = UUID()
        modelLoadTask?.cancel()
        modelLoadID = connectID
        modelLoadProviderID = .chatGPT
        models = []
        do {
            try await signIn()
            guard modelLoadID == connectID else { return }
            await loadModels(for: .chatGPT)
        } catch {
            if modelLoadID == connectID { report(error) }
        }
    }

    var canTellMeMore: Bool {
        !isLoading && draft.isEmpty && attachmentIDs.isEmpty &&
            thread?.messages.last?.role == .pet && thread?.messages.last?.status == .complete
    }

    func select(providerID: ProviderID, modelID: String) throws {
        guard !isShuttingDown, !isLoading else { throw ChatCoordinator.Error.busy }
        let new = try coordinator.newThread(providerID: providerID, modelID: modelID)
        do {
            for id in attachmentIDs { try removeAttachment(id) }
        } catch {
            try coordinator.deleteThread(new.id)
            throw error
        }
        currentThreadID = new.id
        selectedProviderID = providerID
        selectedModelID = modelID
        defaults.set(providerID.rawValue, forKey: "PetChat.selectedProviderID")
        defaults.set(modelID, forKey: "PetChat.selectedModelID")
        resetDraft()
    }

    func newChat() throws { try select(providerID: selectedProviderID, modelID: selectedModelID) }

    func deleteCurrentChat() throws {
        guard !isShuttingDown, !isLoading else { throw ChatCoordinator.Error.busy }
        guard let id = currentThreadID else { return }
        try coordinator.deleteThread(id)
        currentThreadID = coordinator.threads.last?.id
        if let thread { selectedProviderID = thread.providerID; selectedModelID = thread.modelID }
        resetDraft()
    }

    private func resetDraft() {
        draftContextID = UUID()
        draft = ""
        attachmentIDs = []
        errorMessage = nil
        canRetrySubmission = false
    }

    func attachImage(_ bytes: Data) throws {
        guard let id = currentThreadID else { throw ChatCoordinator.Error.missingThread }
        guard !isShuttingDown, !isLoading else { throw ChatCoordinator.Error.busy }
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
        guard !isShuttingDown, let threadID = currentThreadID, !isLoading, !isCapturing,
              let capture = capture ?? captureRegion else { return }
        let contextID = draftContextID
        isCapturing = true
        let task = Task { try await capture() }
        captureTask = task
        defer { isCapturing = false; captureTask = nil }
        do {
            let bytes = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard draftContextID == contextID, currentThreadID == threadID else { return }
            if let bytes { try attachImage(bytes) }
        } catch {
            if draftContextID == contextID, currentThreadID == threadID { report(error) }
        }
    }

    func submit() async {
        guard !isShuttingDown, let id = currentThreadID, !isLoading else { return }
        let text = draft
        let images = attachmentIDs
        let submissionID = UUID()
        activeSubmissionID = submissionID
        isLoading = true
        errorMessage = nil
        canRetrySubmission = false
        let task = Task { try await coordinator.send(text: text, attachmentIDs: images, threadID: id) }
        submissionTask = task
        defer {
            if activeSubmissionID == submissionID {
                activeSubmissionID = nil
                submissionTask = nil
                isLoading = false
            }
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if activeSubmissionID == submissionID, currentThreadID == id,
               thread?.messages.last?.status == .complete {
                if draft == text { draft = "" }
                attachmentIDs.removeAll { images.contains($0) }
            }
        } catch {
            if activeSubmissionID == submissionID {
                errorMessage = error.localizedDescription
                canRetrySubmission = true
            }
        }
    }

    func tellMeMore() async {
        guard canTellMeMore else { return }
        draft = ChatCoordinator.expansionQuestion
        await submit()
    }

    func stop() async {
        guard let id = currentThreadID else { return }
        let submissionID = activeSubmissionID
        do { try await coordinator.stop(threadID: id) }
        catch {
            if activeSubmissionID == submissionID || activeSubmissionID == nil {
                report(error)
            }
        }
        if activeSubmissionID == submissionID {
            submissionTask?.cancel()
            submissionTask = nil
            activeSubmissionID = nil
            isLoading = false
        }
    }

    func signOutChatGPT() async {
        if modelLoadProviderID == .chatGPT { cancelModelLoad() }
        if selectedProviderID == .chatGPT { activeSubmissionID = nil }
        do { try await signOut() } catch { report(error) }
        do { try await coordinator.stopAll(providerID: .chatGPT) } catch { report(error) }
        if selectedProviderID == .chatGPT {
            submissionTask?.cancel()
            submissionTask = nil
            models = []
            activeSubmissionID = nil
            isLoading = false
        }
    }

    func shutdown() async {
        isShuttingDown = true
        cancelModelLoad()
        draftContextID = UUID()
        captureTask?.cancel()
        activeSubmissionID = nil
        isLoading = false
        await auth.shutdown()
        do { try await coordinator.stopAll() } catch { report(error) }
        submissionTask?.cancel()
        submissionTask = nil
    }

    private func cancelModelLoad() {
        modelLoadID = nil
        modelLoadTask?.cancel()
        modelLoadTask = nil
        modelLoadProviderID = nil
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
        canRetrySubmission = false
    }
}
