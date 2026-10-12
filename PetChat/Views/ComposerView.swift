import AppKit
import SwiftUI

struct ComposerView: View {
    @Bindable var model: AppModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.attachmentIDs.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(model.attachmentIDs, id: \.self) { id in
                            VStack(spacing: 2) {
                                AttachmentImage(bytes: model.imageData(for: id))
                                Button("Remove image") {
                                    do { try model.removeAttachment(id) } catch { model.report(error) }
                                }
                                .font(.caption)
                                .disabled(model.isLoading)
                                .accessibilityLabel("Remove image")
                            }
                        }
                    }
                }.frame(height: 76)
            }
            TextEditor(text: $model.draft)
                .focused($isFocused)
                .onAppear { if NSApp.isActive { isFocused = true } }
                .frame(height: 58)
                .accessibilityLabel("Message")
            HStack {
                Button("Capture area") { Task { await model.captureImage() } }
                    .disabled(model.isLoading || model.isCapturing)
                    .accessibilityLabel("Capture area")
                Button("Paste image") {
                    do { try model.pasteImage() } catch { model.report(error) }
                }
                .disabled(model.isLoading || model.isCapturing)
                .accessibilityLabel("Paste image")
                Spacer()
            }
            HStack {
                Button("Stop") { Task { await model.stop() } }
                    .disabled(!model.isLoading)
                    .accessibilityLabel("Stop")
                Spacer()
                Button("Send") { Task { await model.submit() } }
                    .disabled(model.isLoading || model.isCapturing || (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachmentIDs.isEmpty))
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Send")
            }
        }
        .padding(10)
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
