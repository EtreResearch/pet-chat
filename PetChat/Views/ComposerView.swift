import AppKit
import SwiftUI

struct ComposerView: View {
    @Bindable var model: AppModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.attachmentIDs.isEmpty {
                Text("\(model.attachmentIDs.count) image attached")
                    .font(.caption)
                    .accessibilityLabel("\(model.attachmentIDs.count) image attached")
            }
            TextEditor(text: $model.draft)
                .focused($isFocused)
                .onAppear { if NSApp.isActive { isFocused = true } }
                .frame(height: 58)
                .accessibilityLabel("Message")
            HStack {
                Button("Stop") { Task { await model.stop() } }
                    .disabled(!model.isLoading)
                    .accessibilityLabel("Stop")
                Spacer()
                Button("Send") { Task { await model.submit() } }
                    .disabled(model.isLoading || (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachmentIDs.isEmpty))
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Send")
            }
        }
        .padding(10)
    }
}
