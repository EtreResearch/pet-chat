import Foundation

enum ContextBuilder {
    static func build(
        thread: ChatThread,
        currentText: String,
        currentAttachmentIDs: [UUID],
        contextWindowTokens: Int?
    ) -> [PromptMessage] {
        let current = PromptMessage(role: .user, text: currentText, attachmentIDs: currentAttachmentIDs)
        let budget = contextWindowTokens.map { min(8_000, max(0, $0 - 1_024)) } ?? 8_000
        var remaining = budget - estimate(current.text)
        var selected: [[PromptMessage]] = []
        var pairs: [[PromptMessage]] = []

        for message in thread.messages {
            if message.role == .user {
                pairs.append([PromptMessage(role: .user, text: message.text, attachmentIDs: [])])
            } else if message.status == .complete, pairs.last?.count == 1 {
                pairs[pairs.count - 1].append(PromptMessage(role: .assistant, text: message.text, attachmentIDs: []))
            }
        }

        for pair in pairs.reversed() where pair.count == 2 {
            let cost = pair.reduce(0) { $0 + estimate($1.text) }
            if !selected.isEmpty && cost > remaining { break }
            selected.append(pair)
            remaining -= cost
        }

        return selected.reversed().flatMap { $0 } + [current]
    }

    private static func estimate(_ text: String) -> Int {
        // shortcut: UTF-8 byte count conservatively estimates tokens; use provider-native tokenization when available.
        text.utf8.count + 8
    }
}
