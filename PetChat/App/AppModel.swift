import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    let coordinator: ChatCoordinator
    private let auth: ChatGPTOAuthClient
    private(set) var currentThreadID: UUID?
    private(set) var selectedProviderID: ProviderID = .ollama
    private(set) var selectedModelID = ""
    var draft = ""
    var attachmentIDs: [UUID] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var models: [ProviderModel] = []

    var thread: ChatThread? { coordinator.threads.first { $0.id == currentThreadID } }

    init(coordinator: ChatCoordinator, auth: ChatGPTOAuthClient = ChatGPTOAuthClient()) {
        self.coordinator = coordinator
        self.auth = auth
        if let last = coordinator.threads.last {
            currentThreadID = last.id
            selectedProviderID = last.providerID
            selectedModelID = last.modelID
        }
    }

    func loadModels(for providerID: ProviderID) async {
        selectedProviderID = providerID
        models = []
        do { models = try await coordinator.models(for: providerID); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func connectChatGPT() async {
        do {
            _ = try await auth.signIn()
            await loadModels(for: .chatGPT)
        } catch { errorMessage = error.localizedDescription }
    }

    func select(providerID: ProviderID, modelID: String) throws {
        let new = try coordinator.newThread(providerID: providerID, modelID: modelID)
        currentThreadID = new.id
        selectedProviderID = providerID
        selectedModelID = modelID
        draft = ""
        attachmentIDs = []
        errorMessage = nil
    }

    func newChat() throws { try select(providerID: selectedProviderID, modelID: selectedModelID) }

    func deleteCurrentChat() throws {
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
            if thread?.messages.last?.status == .complete {
                draft = ""
                attachmentIDs = []
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func retry() async { await submit() }

    func tellMeMore() async {
        draft = "Tell me more about your last answer."
        await submit()
    }

    func stop() async {
        guard let id = currentThreadID else { return }
        await coordinator.stop(threadID: id)
    }
}
