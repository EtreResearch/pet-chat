import SwiftUI

struct ChatPanelView: View {
    @Bindable var model: AppModel
    let onClose: () -> Void
    let onChangeModel: () -> Void

    private static let helpSuggestion = "What can you help with?"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.border)
            messages
            if let error = model.errorMessage { errorBar(error) }
            ComposerView(model: model)
        }
        .background(Palette.panelBackground)
        .font(.system(size: model.textSize))
        .frame(width: 440, height: 530)
        .task(id: model.thread?.id) { await model.loadModels(for: model.selectedProviderID) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "pawprint")
                .font(.system(size: 20))
                .foregroundStyle(Palette.accent)
                .frame(width: 44, height: 44)
                .background(Palette.sage, in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pet Chat").font(.system(size: 19, weight: .semibold)).lineLimit(1)
                Text("\(model.selectedProviderID.displayName) · \(model.selectedModelID)")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer()
            Menu {
                Button("New Chat") { do { try model.newChat() } catch { model.report(error) } }
                Button("Delete Chat", role: .destructive) {
                    do { try model.deleteCurrentChat() } catch { model.report(error) }
                }
                Button("Change model") { onChangeModel() }
            } label: {
                // One Text, so the menu keeps the chevron trailing instead of treating it as a leading icon.
                Text("Chat   ") + Text(Image(systemName: "chevron.down")).font(.system(size: 10, weight: .medium))
            }
            // ponytail: a borderless menu keeps the native menu button (custom plain-styled menus drop out of the
            // accessibility tree); the sage pill is drawn around it.
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .font(.system(size: 13, weight: .medium))
            .fixedSize()
            .accessibilityLabel("Chat")
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Palette.sage, in: RoundedRectangle(cornerRadius: 8))
            .disabled(model.isLoading)
            Button(action: onClose) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    Text("Close").font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Palette.headerBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(Palette.headerBackground)
    }

    private var messages: some View {
        let messages = model.thread?.messages ?? []
        let lastPetID = messages.last { $0.role == .pet }?.id
        return ScrollViewReader { proxy in
            ScrollView {
                // ponytail: a plain VStack re-lays-out and re-parses markdown for every row on each streamed token;
                // switch to LazyVStack if long chats lag.
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ChatMessage.daySections(messages, now: Date(), calendar: .current), id: \.title) { section in
                        Text(section.title)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondaryText)
                            .frame(maxWidth: .infinity)
                        ForEach(section.messages) { message in
                            row(message, isLastReply: message.id == lastPetID)
                                .id(message.id)
                        }
                    }
                    // Provider model discovery runs before Pet's reply exists; show the dots until it does.
                    if model.isLoading && messages.last?.role != .pet { row(Self.pendingReply, isLastReply: false) }
                    chips(afterReply: !messages.isEmpty)
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
            .onChange(of: messages.last?.text) { _, _ in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onChange(of: messages.count) { _, _ in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            // Suggestions appear once a reply finishes; keep them in view.
            .onChange(of: model.isLoading) { _, _ in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onAppear { Task { @MainActor in proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
        }
    }

    private static let bottomID = "bottom"
    private static let pendingReply = ChatMessage(role: .pet, text: "", createdAt: nil)

    private func row(_ message: ChatMessage, isLastReply: Bool) -> some View {
        let last = model.thread?.messages.last
        let isStreaming = model.isLoading && message.role == .pet && (message.id == last?.id || message.id == Self.pendingReply.id)
        // The error bar's Retry covers a failed generation, so the reply Retry steps aside while it shows.
        let showsRetry = isLastReply && model.canRegenerate && !model.canRetrySubmission
        return MessageRowView(message: message, outsideContext: model.excludedMessageIDs.contains(message.id),
                              isStreaming: isStreaming,
                              imageData: Dictionary(uniqueKeysWithValues: message.attachmentIDs.compactMap { id in
                                  model.imageData(for: id).map { (id, $0) }
                              }),
                              textSize: model.textSize,
                              onRetry: showsRetry ? { Task { await model.regenerateLastReply() } } : nil)
    }

    /// Suggestions under the last reply, or a single starter in an empty chat.
    @ViewBuilder private func chips(afterReply: Bool) -> some View {
        let startsChat = !afterReply && model.draft.isEmpty && model.attachmentIDs.isEmpty && !model.isLoading
        if afterReply ? model.canTellMeMore : startsChat {
            HStack(spacing: 8) {
                chip(Self.helpSuggestion) { Task { await model.sendSuggestion(Self.helpSuggestion) } }
                if afterReply { chip("Tell me more") { Task { await model.tellMeMore() } } }
            }
            .padding(.top, 4)
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
            }
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Palette.headerBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func errorBar(_ error: String) -> some View {
        HStack(spacing: 8) {
            Text(error)
                .font(.system(size: 11))
                .lineLimit(2)
                .textSelection(.enabled)
                .help(error)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.canRetrySubmission {
                Button("Retry") { Task { await model.retry() } }
            }
            if model.selectedProviderID == .chatGPT {
                Button("Reconnect") { Task { await model.connectChatGPT() } }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.errorFill, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }
}
