import SwiftUI

struct SetupView: View {
    @Bindable var model: AppModel
    let onSelected: () -> Void
    @State private var providerID: ProviderID = .ollama
    @State private var modelID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a provider and model").font(.headline)
            Picker("Provider", selection: $providerID) {
                Text("Ollama").tag(ProviderID.ollama)
                Text("ChatGPT").tag(ProviderID.chatGPT)
            }
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
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            if providerID == .chatGPT {
                Button("Connect ChatGPT") { Task { await model.connectChatGPT() } }
            } else {
                Button("Refresh models") { Task { await model.loadModels(for: .ollama) } }
            }
            Button("Start chatting") {
                do { try model.select(providerID: providerID, modelID: modelID); onSelected() }
                catch { model.report(error) }
            }
            .disabled(!model.models.contains { $0.id == modelID })
        }
        .padding(20)
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
