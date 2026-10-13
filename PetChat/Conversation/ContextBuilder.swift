import Foundation

enum ContextBuilder {
    private struct Pair {
        let messages: [PromptMessage]
        let ids: [UUID]
    }

    static func build(
        thread: ChatThread,
        currentText: String,
        currentAttachmentIDs: [UUID],
        contextWindowTokens: Int?
    ) -> [PromptMessage] {
        let current = PromptMessage(role: .user, text: currentText, attachmentIDs: currentAttachmentIDs)
        return selectedPairs(thread: thread, currentText: currentText, contextWindowTokens: contextWindowTokens)
            .flatMap(\.messages) + [current]
    }

    static func includedHistoryIDs(thread: ChatThread, currentText: String,
                                   contextWindowTokens: Int?) -> Set<UUID> {
        Set(selectedPairs(thread: thread, currentText: currentText, contextWindowTokens: contextWindowTokens)
            .flatMap(\.ids))
    }

    private static func selectedPairs(thread: ChatThread, currentText: String,
                                      contextWindowTokens: Int?) -> [Pair] {
        let budget = contextWindowTokens.map { min(8_000, max(0, $0 - 1_024)) } ?? 8_000
        var remaining = budget - estimate(currentText)
        var selected: [Pair] = []
        var pairs: [Pair] = []

        for message in thread.messages {
            if message.role == .user {
                pairs.append(Pair(messages: [PromptMessage(role: .user, text: message.text, attachmentIDs: [])],
                                  ids: [message.id]))
            } else if message.status == .complete, pairs.last?.messages.count == 1 {
                let previous = pairs.removeLast()
                pairs.append(Pair(messages: previous.messages + [PromptMessage(role: .assistant, text: message.text, attachmentIDs: [])],
                                  ids: previous.ids + [message.id]))
            }
        }

        for pair in pairs.reversed() where pair.messages.count == 2 {
            let cost = pair.messages.reduce(0) { $0 + estimate($1.text) }
            if !selected.isEmpty && cost > remaining { break }
            selected.append(pair)
            remaining -= cost
        }

        return selected.reversed()
    }

    private static func estimate(_ text: String) -> Int {
        // shortcut: UTF-8 byte count conservatively estimates tokens; use provider-native tokenization when available.
        text.utf8.count + 8
    }
}
