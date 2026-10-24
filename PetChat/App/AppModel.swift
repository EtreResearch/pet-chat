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
    var petColor: PetColor { didSet { defaults.set(petColor.rawValue, forKey: "PetChat.petColor") } }
    var draft = ""
    var attachmentIDs: [UUID] = []
    var captureRegion: (@MainActor () async throws -> Data?)?
    private(set) var isCapturing = false
    private(set) var isLoading = false
    private var draftContextID = UUID()
    private var activeSubmissionID: UUID?
    private(set) var errorMessage: String?
    private(set) var canRetrySubmission = false
    private enum Generation { case submit, regenerate }
    /// What the error-bar Retry re-runs; set whenever `canRetrySubmission` turns on.
    private var failedGeneration = Generation.submit
    /// A message on its way into the chat, kept until its Turn is recorded or the send ends without it.
    private struct PendingSend {
        let text: String
        let images: [UUID]
        /// True when the message came from the Draft, so a send that never reaches the chat puts it back.
        let restoresDraft: Bool
        let lastMessageID: UUID?
    }
    private var pendingSend: PendingSend?
    private(set) var models: [ProviderModel] = []
    private var modelLoadID: UUID?
    private var modelLoadProviderID: ProviderID?
    private var modelLoadTask: Task<[ProviderModel], Error>?
    private var submissionTask: Task<Void, Error>?
    private var isConnectingChatGPT = false
    private(set) var isSigningOutChatGPT = false

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
        petColor = PetColor(rawValue: defaults.string(forKey: "PetChat.petColor") ?? "") ?? .blue
        self.loginItemController = loginItemController ?? LoginItemController(defaults: defaults)
        self.signIn = signIn ?? { _ = try await auth.signIn() }
        self.signOut = signOut ?? { try await auth.signOut() }
        if let last = coordinator.threads.last {
            currentThreadID = last.id
            selectedProviderID = last.providerID
            selectedModelID = last.modelID
            if last.messages.last?.status == .failed, last.lastAnsweredQuestion != nil {
                // The failed Turn is already in the chat; Retry re-asks it in place and the Draft stays empty.
                errorMessage = ChatCoordinator.Error.incompleteResponse.localizedDescription
                canRetrySubmission = true
                failedGeneration = .regenerate
            }
        } else {
            selectedProviderID = ProviderID(rawValue: defaults.string(forKey: "PetChat.selectedProviderID") ?? "") ?? .ollama
            selectedModelID = defaults.string(forKey: "PetChat.selectedModelID") ?? ""
        }
    }

    func loadModels(for providerID: ProviderID) async {
        guard !isShuttingDown, providerID != .chatGPT || !isSigningOutChatGPT else { return }
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
        guard !isShuttingDown, !isConnectingChatGPT, !isSigningOutChatGPT else { return }
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

    var canSend: Bool {
        !isLoading && !isCapturing && !(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachmentIDs.isEmpty)
    }

    var canRegenerate: Bool {
        !isLoading && !isCapturing && thread?.lastAnsweredQuestion != nil
    }

    func select(providerID: ProviderID, modelID: String) throws {
        guard !isShuttingDown, !isLoading else { throw ChatCoordinator.Error.busy }
        let new = try coordinator.newThread(providerID: providerID, modelID: modelID)
        let (oldThreadID, abandoned) = (currentThreadID, attachmentIDs)
        currentThreadID = new.id
        selectedProviderID = providerID
        selectedModelID = modelID
        defaults.set(providerID.rawValue, forKey: "PetChat.selectedProviderID")
        defaults.set(modelID, forKey: "PetChat.selectedModelID")
        resetDraft()
        // ponytail: best-effort after the switch commits; a file that fails to delete stays in the old chat's folder until that chat is deleted.
        if let oldThreadID { for id in abandoned { try? coordinator.removeDraftAttachment(id, threadID: oldThreadID) } }
    }

    func newChat() throws { try select(providerID: selectedProviderID, modelID: selectedModelID) }

    func deleteCurrentChat() throws {
        guard !isShuttingDown, !isLoading else { throw ChatCoordinator.Error.busy }
        guard let id = currentThreadID else { return }
        // Deletion can commit and still throw for leftover file cleanup; follow the committed state either way.
        defer {
            if !coordinator.threads.contains(where: { $0.id == id }) {
                currentThreadID = coordinator.threads.last?.id
                if let thread { selectedProviderID = thread.providerID; selectedModelID = thread.modelID }
                resetDraft()
            }
        }
        try coordinator.deleteThread(id)
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
        guard !isShuttingDown, !isLoading else { throw ChatCoordinator.Error.busy }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let images = try urls.map { url -> Data in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw AttachmentStore.Error.invalidImage
                }
                return png
            }
            for image in images { try attachImage(image) }
            return
        }
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
        await send(text: draft, images: attachmentIDs, restoresDraft: true)
    }

    /// Sends one message. A Draft is emptied as soon as the send starts; see `settlePendingSend()` for when it returns.
    private func send(text: String, images: [UUID], restoresDraft: Bool) async {
        let pending = PendingSend(text: text, images: images, restoresDraft: restoresDraft,
                                  lastMessageID: thread?.messages.last?.id)
        await generate(.submit, pending: pending) { [coordinator] id in
            try await coordinator.send(text: text, attachmentIDs: images, threadID: id)
        }
    }

    /// Called once a send ends without success (error, Stop, shutdown, sign-out). If its Turn reached the chat, the
    /// Draft stays empty and Retry re-asks the Turn in place; otherwise the message returns to the Draft unless the
    /// user has started a new one.
    private func settlePendingSend() {
        guard let pending = pendingSend else { return }
        pendingSend = nil
        if thread?.messages.last?.id != pending.lastMessageID {
            failedGeneration = .regenerate
        } else if pending.restoresDraft, draft.isEmpty, attachmentIDs.isEmpty {
            draft = pending.text
            attachmentIDs = pending.images
        } else {
            // ponytail: unsent images left out of the Draft stay in the chat folder until the chat is deleted.
            canRetrySubmission = false
        }
    }

    func regenerateLastReply() async {
        guard canRegenerate else { return }
        await generate(.regenerate) { [coordinator] id in try await coordinator.regenerateLastReply(threadID: id) }
    }

    /// Error-bar Retry: re-runs whichever generation failed, so a failed regenerate never sends the composer draft.
    func retry() async {
        switch failedGeneration {
        case .submit: await submit()
        case .regenerate: await regenerateLastReply()
        }
    }

    /// Runs one generation in the current chat.
    private func generate(_ kind: Generation, pending: PendingSend? = nil,
                          _ work: @escaping @MainActor @Sendable (UUID) async throws -> Void) async {
        guard !isShuttingDown, let id = currentThreadID, !isLoading else { return }
        guard selectedProviderID != .chatGPT || !isSigningOutChatGPT else { return }
        if let pending, pending.restoresDraft {
            draft = ""
            attachmentIDs = []
        }
        pendingSend = pending
        let submissionID = UUID()
        activeSubmissionID = submissionID
        isLoading = true
        errorMessage = nil
        canRetrySubmission = false
        let task = Task { try await work(id) }
        submissionTask = task
        defer {
            if activeSubmissionID == submissionID {
                activeSubmissionID = nil
                submissionTask = nil
                pendingSend = nil
                isLoading = false
            }
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if activeSubmissionID == submissionID {
                errorMessage = error.localizedDescription
                canRetrySubmission = true
                failedGeneration = kind
                settlePendingSend()
            }
        }
    }

    func tellMeMore() async {
        guard canTellMeMore else { return }
        await send(text: ChatCoordinator.expansionQuestion, images: [], restoresDraft: false)
    }

    /// Suggestion chip: sends `text` without touching the Draft; ignored while the composer holds a draft or image.
    func sendSuggestion(_ text: String) async {
        guard !isLoading, draft.isEmpty, attachmentIDs.isEmpty else { return }
        await send(text: text, images: [], restoresDraft: false)
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
            settlePendingSend()
            submissionTask?.cancel()
            submissionTask = nil
            activeSubmissionID = nil
            isLoading = false
        }
    }

    func signOutChatGPT() async {
        guard !isSigningOutChatGPT else { return }
        isSigningOutChatGPT = true
        defer { isSigningOutChatGPT = false }
        errorMessage = nil
        canRetrySubmission = false
        if modelLoadProviderID == .chatGPT { cancelModelLoad() }
        if selectedProviderID == .chatGPT { activeSubmissionID = nil }
        do { try await coordinator.stopAll(providerID: .chatGPT) } catch { report(error) }
        if selectedProviderID == .chatGPT {
            settlePendingSend()
            submissionTask?.cancel()
            submissionTask = nil
            models = []
            activeSubmissionID = nil
            isLoading = false
        }
        do { try await signOut() } catch { report(error) }
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
        settlePendingSend()
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
