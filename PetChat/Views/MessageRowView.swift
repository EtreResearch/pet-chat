import SwiftUI

struct MessageRowView: View {
    let message: ChatMessage
    let outsideContext: Bool
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(message.role == .user ? "You" : "Pet")
                .font(.caption.bold())
            if !message.text.isEmpty { Text(message.text).textSelection(.enabled) }
            if !message.attachmentIDs.isEmpty {
                Text("\(message.attachmentIDs.count) image attached").font(.caption)
            }
            if message.role == .pet && message.status != .complete && !isStreaming {
                Text(message.status == .stopped ? "Stopped" : "Interrupted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if outsideContext {
                Text("Outside current model context")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .background(message.role == .user ? Color.blue.opacity(0.12) : Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}
