import Carbon
import XCTest
@testable import PetChat

@MainActor
final class ShortcutStateTests: XCTestCase {
    func testConflictKeepsPreviouslyRegisteredShortcut() throws {
        let first = GlobalShortcutController(onSummon: {})
        let second = GlobalShortcutController(onSummon: {})
        let occupied = Shortcut(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | cmdKey))
        let previous = Shortcut(keyCode: UInt32(kVK_F18), modifiers: UInt32(controlKey | optionKey | cmdKey))
        try first.register(occupied)
        try second.register(previous)
        XCTAssertThrowsError(try second.register(occupied)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already in use"))
        }
        XCTAssertEqual(second.shortcut, previous)
    }

    func testCarbonEventSummonsOnlyItsRegisteredController() throws {
        var firstCalls = 0, secondCalls = 0
        let first = GlobalShortcutController(onSummon: { firstCalls += 1 })
        let second = GlobalShortcutController(onSummon: { secondCalls += 1 })
        try first.register(Shortcut(keyCode: UInt32(kVK_F16), modifiers: UInt32(controlKey | optionKey | cmdKey)))
        try second.register(Shortcut(keyCode: UInt32(kVK_F15), modifiers: UInt32(controlKey | optionKey | cmdKey)))
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                                  EventAttributes(kEventAttributeUserEvent), &event), noErr)
        let carbonEvent = try XCTUnwrap(event)
        defer { ReleaseEvent(carbonEvent) }
        var id = EventHotKeyID(signature: 0x50455443, id: first.eventID)
        XCTAssertEqual(SetEventParameter(carbonEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        MemoryLayout<EventHotKeyID>.size, &id), noErr)
        XCTAssertEqual(SendEventToEventTarget(carbonEvent, GetApplicationEventTarget()), noErr)
        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(secondCalls, 0)
    }

    func testShortcutPersistsOnlyAfterSuccessfulRegistration() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let controller = GlobalShortcutController(defaults: defaults, onSummon: {})
        let shortcut = Shortcut(keyCode: UInt32(kVK_F17), modifiers: UInt32(controlKey | optionKey | cmdKey))
        try controller.register(shortcut)
        XCTAssertEqual(GlobalShortcutController.savedShortcut(in: defaults), shortcut)
        XCTAssertThrowsError(try controller.register(Shortcut(keyCode: 49, modifiers: 0)))
        XCTAssertEqual(GlobalShortcutController.savedShortcut(in: defaults), shortcut)
    }
}
