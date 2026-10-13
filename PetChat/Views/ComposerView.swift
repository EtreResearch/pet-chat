import AppKit
import SwiftUI

struct ComposerView: View {
    @Bindable var model: AppModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Message Pet").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                if !model.attachmentIDs.isEmpty { thumbnails }
                editor
                HStack(spacing: 8) {
                    secondaryButton("Capture area", systemImage: "viewfinder") { Task { await model.captureImage() } }
                    secondaryButton("Paste image", systemImage: "photo.badge.plus") {
                        do { try model.pasteImage() } catch { model.report(error) }
                    }
                    Spacer()
                    primaryButton
                }
            }
            .padding(10)
            .background(Palette.headerBackground, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.accent, lineWidth: 1.5))
            Text("Enter to send · Shift + Enter for a new line")
                .font(.caption)
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var thumbnails: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(model.attachmentIDs, id: \.self) { id in
                    AttachmentImage(bytes: model.imageData(for: id))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                do { try model.removeAttachment(id) } catch { model.report(error) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isLoading)
                            .accessibilityLabel("Remove image")
                            .padding(2)
                        }
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: 52)
    }

    /// Grows from one line to five, then scrolls: the hidden copy of the draft sets the height.
    private var editor: some View {
        Text(model.draft + " ")
            .lineLimit(1...5)
            .padding(.horizontal, 5) // matches NSTextView's line fragment padding
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay {
                TextEditor(text: $model.draft)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($isFocused)
                    .onAppear { if NSApp.isActive { isFocused = true } }
                    .onKeyPress(.return, phases: [.down, .repeat]) { handleReturn($0) }
                    .accessibilityLabel("Message")
            }
    }

    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.shift) { return .ignored }
        if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return .ignored }
        if model.canSend { Task { await model.submit() } }
        return .handled
    }

    private func secondaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Palette.secondaryFill, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(Palette.secondaryText)
        .disabled(model.isLoading || model.isCapturing)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var primaryButton: some View {
        if model.isLoading {
            primaryLabel("Stop", systemImage: "stop.fill", enabled: true) { Task { await model.stop() } }
        } else {
            primaryLabel("Send", systemImage: "arrow.up", enabled: model.canSend) { Task { await model.submit() } }
        }
    }

    private func primaryLabel(_ title: String, systemImage: String, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Image(systemName: systemImage)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Palette.accentFill, in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}

struct AttachmentImage: View {
    let bytes: Data?
    var body: some View {
        Group {
            if let bytes, let image = NSImage(data: bytes) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 52)
        .accessibilityLabel("Attached image")
    }
}
