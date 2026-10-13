import SwiftUI

struct ChatPanelView: View {
    @Bindable var model: AppModel
    let onClose: () -> Void
    let onChangeModel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Pet Chat").font(.headline)
                    Text("\(model.selectedProviderID.displayName) · \(model.selectedModelID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Chat") {
                    Button("New Chat") { do { try model.newChat() } catch { model.report(error) } }
                    Button("Delete Chat", role: .destructive) {
                        do { try model.deleteCurrentChat() } catch { model.report(error) }
                    }
                    Button("Change model") { onChangeModel() }
                }
                .disabled(model.isLoading)
                Button("Close") { onClose() }
                    .accessibilityLabel("Close")
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.thread?.messages ?? []) { message in
                            MessageRowView(message: message, outsideContext: model.excludedMessageIDs.contains(message.id),
                                           isStreaming: model.isLoading && message.id == model.thread?.messages.last?.id,
                                           imageData: Dictionary(uniqueKeysWithValues: message.attachmentIDs.compactMap { id in
                                               model.imageData(for: id).map { (id, $0) }
                                           }))
                                .id(message.id)
                        }
                        if model.isLoading {
                            ProgressView("Thinking").frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: model.thread?.messages.last?.text) { _, _ in
                    if let id = model.thread?.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onAppear {
                    if let id = model.thread?.messages.last?.id {
                        Task { @MainActor in proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            if let error = model.errorMessage {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.primary)
                    Spacer()
                    if model.canRetrySubmission {
                        Button("Retry") { Task { await model.submit() } }
                    }
                    if model.selectedProviderID == .chatGPT {
                        Button("Reconnect") { Task { await model.connectChatGPT() } }
                    }
                }
                .padding(.horizontal, 10)
            }
            Button("Tell me more") { Task { await model.tellMeMore() } }
                .disabled(!model.canTellMeMore)
                .accessibilityLabel("Tell me more")
                .padding(.bottom, 4)
            Divider()
            ComposerView(model: model)
        }
        .font(.system(size: model.textSize))
        .frame(width: 340, height: 420)
        .task(id: model.thread?.id) { await model.loadModels(for: model.selectedProviderID) }
    }
}
