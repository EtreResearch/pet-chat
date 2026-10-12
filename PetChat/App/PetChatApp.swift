import SwiftUI

@main
struct PetChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            PetChatRootView()
        }
    }
}

private struct PetChatRootView: View {
    @State private var model: AppModel?
    @State private var launchError: String?
    @State private var panelOpen = true
    @State private var choosingModel = false

    var body: some View {
        VStack(spacing: 0) {
            if let model, panelOpen {
                if model.thread == nil || choosingModel {
                    SetupView(model: model, onSelected: { choosingModel = false })
                } else {
                    ChatPanelView(model: model, onClose: { panelOpen = false },
                                  onChangeModel: { choosingModel = true })
                }
            } else if let launchError {
                Text(launchError).padding()
            }
            Button { panelOpen.toggle() } label: { PetView() }
                .buttonStyle(.plain)
                .accessibilityLabel("Pet")
        }
        .onExitCommand { panelOpen = false }
        .task {
            guard model == nil else { return }
            do {
                let attachments = AttachmentStore()
                let store = try LocalChatStore()
                let auth = ChatGPTOAuthClient()
                let coordinator = try ChatCoordinator(
                    providers: [.ollama: OllamaProvider(), .chatGPT: OpenAIPlanProvider(auth: auth)],
                    store: store, attachments: attachments)
                model = AppModel(coordinator: coordinator, auth: auth)
            } catch { launchError = error.localizedDescription }
        }
    }
}
