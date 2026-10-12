import SwiftUI

struct SetupView: View {
    @Bindable var model: AppModel
    let onSelected: () -> Void
    @State private var providerID: ProviderID = .ollama
    @State private var modelID = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose a provider and model").font(.headline)
                Picker("Provider", selection: $providerID) {
                    Text("Ollama").tag(ProviderID.ollama)
                    Text("ChatGPT").tag(ProviderID.chatGPT)
                }
                .accessibilityLabel("Provider")
                .onChange(of: providerID) { _, value in
                    modelID = ""
                    Task { await model.loadModels(for: value) }
                }
                Picker("Model", selection: $modelID) {
                    Text("Choose model").tag("")
                    ForEach(model.models) { available in
                        Text(available.displayName).tag(available.id)
                    }
                }
                .accessibilityLabel("Model")
                Text(providerID == .ollama
                     ? "Ollama runs locally. Start Ollama and download a model, then refresh."
                     : "Connect your ChatGPT account and allow plan usage. Credentials stay in this app’s Keychain items.")
                    .font(.caption)
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.primary) }
                if providerID == .chatGPT {
                    Button("Connect ChatGPT") { Task { await model.connectChatGPT() } }
                } else {
                    Button("Refresh models") { Task { await model.loadModels(for: .ollama) } }
                }
                LoginItemControl(controller: model.loginItemController)
                Text("Images are sent only when you press Send. Capture area asks permission after you choose it.")
                    .font(.caption)
                Button("Start chatting") {
                    do { try model.select(providerID: providerID, modelID: modelID); onSelected() }
                    catch { model.report(error) }
                }
                .disabled(!model.models.contains { $0.id == modelID })
            }
            .padding(20)
        }
        .frame(width: 340)
        .task {
            providerID = model.selectedProviderID
            await model.loadModels(for: providerID)
            if model.models.contains(where: { $0.id == model.selectedModelID }) {
                modelID = model.selectedModelID
            }
        }
    }
}
