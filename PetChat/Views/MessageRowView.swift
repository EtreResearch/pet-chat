import AppKit
import SwiftUI

struct MessageRowView: View {
    let message: ChatMessage
    let outsideContext: Bool
    let isStreaming: Bool
    var imageData: [UUID: Data] = [:]
    var textSize: CGFloat = 13
    /// Regenerates this reply; nil hides the Retry action.
    var onRetry: (() -> Void)?

    var body: some View {
        if message.role == .user { userRow } else { petRow }
    }

    private var userRow: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("You")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachmentIDs.isEmpty {
                    HStack {
                        ForEach(message.attachmentIDs, id: \.self) { id in
                            AttachmentImage(bytes: imageData[id])
                        }
                    }
                    .accessibilityLabel("\(message.attachmentIDs.count) image attached")
                }
                if !message.text.isEmpty { Text(message.text).textSelection(.enabled) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Palette.sage, in: RoundedRectangle(cornerRadius: 12))
            // ponytail: the panel is a fixed 440pt wide, so ~75% of its content width is a constant.
            .frame(maxWidth: 300, alignment: .trailing)
            if outsideContext { caption("Outside current model context") }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    private var petRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "pawprint").foregroundStyle(Palette.accent)
                    Text("Pet").fontWeight(.semibold)
                }
                .font(.system(size: 12))
                if isStreaming && message.text.isEmpty {
                    ThinkingDots()
                } else {
                    MarkdownText(text: message.text, baseSize: textSize)
                }
            }
            .accessibilityElement(children: .combine)
            if !isStreaming { actions }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 16) {
            if !message.text.isEmpty { CopyButton(text: message.text) }
            if let onRetry {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Retry")
            }
            if !notes.isEmpty {
                HStack { caption(notes.joined(separator: " · ")) }
                    // A labelled group rather than plain static text, matching how the reply itself is exposed.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(notes.joined(separator: ", "))
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(Palette.secondaryText)
        .padding(.leading, 4)
    }

    /// Grey status notes beside a reply's actions.
    private var notes: [String] {
        var notes: [String] = []
        if message.status != .complete { notes.append(message.status == .stopped ? "Stopped" : "Interrupted") }
        if outsideContext { notes.append("Outside current model context") }
        return notes
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .accessibilityLabel(copied ? "Copied" : "Copy")
    }
}

/// Three pulsing dots shown while Pet has not produced any text yet.
private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 3
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Palette.secondaryText)
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * max(0, sin(phase - Double(index) * 0.8)))
                }
            }
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("Thinking")
    }
}
