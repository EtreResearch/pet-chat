import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    static let `default` = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))

    var label: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        if keyCode == UInt32(kVK_Space) { return text + "Space" }
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            if UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                              OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars) == noErr, length > 0 {
                return text + String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return text + "Key \(keyCode)"
    }
}

@MainActor
final class GlobalShortcutController {
    enum Error: LocalizedError {
        case conflict, invalid, registration(OSStatus)
        var errorDescription: String? {
            switch self {
            case .conflict: "That shortcut is already in use. Choose another combination."
            case .invalid: "Use a shortcut with Control, Option, or Command."
            case .registration(let status): "Could not register the shortcut (\(status))."
            }
        }
    }
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onSummon: () -> Void
    private let defaults: UserDefaults
    private(set) var shortcut: Shortcut?

    init(defaults: UserDefaults = .standard, onSummon: @escaping () -> Void) {
        self.defaults = defaults
        self.onSummon = onSummon
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let data, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            return MainActor.assumeIsolated {
                let controller = Unmanaged<GlobalShortcutController>.fromOpaque(data).takeUnretainedValue()
                guard id.signature == 0x50455443, id.id == controller.eventID else { return OSStatus(eventNotHandledErr) }
                controller.onSummon()
                return noErr
            }
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private static var nextEventID: UInt32 = 0
    private(set) var eventID: UInt32 = 0
    func register(_ shortcut: Shortcut) throws {
        guard shortcut.modifiers & UInt32(controlKey | optionKey | cmdKey) != 0, shortcut.keyCode <= 127 else { throw Error.invalid }
        if self.shortcut == shortcut { return }
        var candidate: EventHotKeyRef?
        Self.nextEventID &+= 1
        let nextID = Self.nextEventID
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: 0x50455443, id: nextID),
                                         GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr else { throw status == eventHotKeyExistsErr ? Error.conflict : Error.registration(status) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate
        eventID = nextID
        self.shortcut = shortcut
        if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: "PetChat.globalShortcut") }
    }

    static func savedShortcut(in defaults: UserDefaults = .standard) -> Shortcut {
        guard let data = defaults.data(forKey: "PetChat.globalShortcut"),
              let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .default }
        return shortcut
    }

    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
