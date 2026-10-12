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
    private(set) var isLoading = false
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
        currentThreadID = coordinator.threads.last?.id
        if let thread { selectedProviderID = thread.providerID; selectedModelID = thread.modelID }
        draft = ""
        attachmentIDs = []
        errorMessage = nil
    }

    func submit() async {
        guard let id = currentThreadID, !isLoading else { return }
        let text = draft
        let images = attachmentIDs
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await coordinator.send(text: text, attachmentIDs: images, threadID: id)
            if currentThreadID == id, thread?.messages.last?.status == .complete,
               draft == text, attachmentIDs == images {
                draft = ""
                attachmentIDs = []
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func retry() async { await submit() }

    func tellMeMore() async {
        draft = ChatCoordinator.expansionQuestion
        await submit()
    }

    func stop() async {
        guard let id = currentThreadID else { return }
        do { try await coordinator.stop(threadID: id) }
        catch { errorMessage = error.localizedDescription }
    }

    func report(_ error: Error) { errorMessage = error.localizedDescription }
}
