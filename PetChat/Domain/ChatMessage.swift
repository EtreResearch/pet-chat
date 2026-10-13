import Foundation

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case user
        case pet
    }

    enum Status: String, Codable {
        case complete
        case stopped
        case failed
    }

    let id: UUID
    let role: Role
    var text: String
    let attachmentIDs: [UUID]
    var status: Status
    // nil for messages saved before timestamps existed.
    var createdAt: Date?

    init(id: UUID = UUID(), role: Role, text: String, attachmentIDs: [UUID] = [], status: Status = .complete,
         createdAt: Date? = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.attachmentIDs = attachmentIDs
        self.status = status
        self.createdAt = createdAt
    }
}

extension ChatMessage {
    /// Groups consecutive messages under "Earlier" (undated), "Today", "Yesterday", or a short date.
    static func daySections(_ messages: [ChatMessage], now: Date, calendar: Calendar) -> [(title: String, messages: [ChatMessage])] {
        var sections: [(title: String, messages: [ChatMessage])] = []
        for message in messages {
            let title = dayTitle(message.createdAt, now: now, calendar: calendar)
            if let last = sections.indices.last, sections[last].title == title {
                sections[last].messages.append(message)
            } else {
                sections.append((title, [message]))
            }
        }
        return sections
    }

    private static func dayTitle(_ date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return "Earlier" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        var style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }
}
