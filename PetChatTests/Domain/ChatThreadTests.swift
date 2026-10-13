import XCTest
@testable import PetChat

final class ChatThreadTests: XCTestCase {
    func testNewThreadKeepsProviderAndModelWithoutInheritedMessages() {
        let old = ChatThread(providerID: .ollama, modelID: "llama3", messages: [
            ChatMessage(role: .user, text: "private history")
        ])
        let next = ChatThread(providerID: .chatGPT, modelID: "gpt-5")

        XCTAssertEqual(old.providerID, .ollama)
        XCTAssertEqual(old.modelID, "llama3")
        XCTAssertEqual(next.providerID, .chatGPT)
        XCTAssertEqual(next.modelID, "gpt-5")
        XCTAssertTrue(next.messages.isEmpty)
    }

    func testThreadAndMessageRoundTripPreservesBindingAndOrder() throws {
        let imageID = UUID()
        let thread = ChatThread(providerID: .ollama, modelID: "vision", messages: [
            ChatMessage(role: .user, text: "look", attachmentIDs: [imageID]),
            ChatMessage(role: .pet, text: "a cat", status: .stopped)
        ])

        let restored = try JSONDecoder().decode(ChatThread.self, from: JSONEncoder().encode(thread))

        XCTAssertEqual(restored.providerID, .ollama)
        XCTAssertEqual(restored.modelID, "vision")
        XCTAssertEqual(restored.messages.map(\.text), ["look", "a cat"])
        XCTAssertEqual(restored.messages[0].attachmentIDs, [imageID])
        XCTAssertEqual(restored.messages[1].status, .stopped)
    }

    func testLegacyMessageJSONWithoutCreatedAtDecodesAsUndated() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","role":"user","text":"old","attachmentIDs":[],"status":"complete"}"#

        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))

        XCTAssertNil(message.createdAt)
    }

    func testCreatedAtRoundTripsThroughJSON() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1234)
        let message = ChatMessage(role: .user, text: "hi", createdAt: date)

        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))

        XCTAssertEqual(restored.createdAt, date)
    }

    func testDaySectionsTitlesAndGrouping() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        }
        let now = at(2026, 10, 13, 15)
        let messages = [
            ChatMessage(role: .user, text: "legacy", createdAt: nil),
            ChatMessage(role: .pet, text: "last year", createdAt: at(2025, 12, 31, 9)),
            ChatMessage(role: .user, text: "older", createdAt: at(2026, 10, 11, 9)),
            ChatMessage(role: .pet, text: "yesterday late", createdAt: at(2026, 10, 12, 23)),
            ChatMessage(role: .user, text: "yesterday early", createdAt: at(2026, 10, 12, 1)),
            ChatMessage(role: .pet, text: "today", createdAt: at(2026, 10, 13, 0))
        ]

        let sections = ChatMessage.daySections(messages, now: now, calendar: calendar)

        XCTAssertEqual(sections.map(\.title), ["Earlier", "Dec 31, 2025", "Oct 11", "Yesterday", "Today"])
        XCTAssertEqual(sections[3].messages.map(\.text), ["yesterday late", "yesterday early"])
    }
}
