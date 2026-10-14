import AppKit
import Observation

@MainActor @Observable
final class DockPreference {
    static let key = "PetChat.showInDock"
    private let defaults: UserDefaults
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void
    private(set) var showInDock: Bool

    init(defaults: UserDefaults = .standard,
         setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) }) {
        self.defaults = defaults
        self.setPolicy = setPolicy
        showInDock = defaults.object(forKey: Self.key) as? Bool ?? true
    }

    func setShowInDock(_ show: Bool) {
        showInDock = show
        defaults.set(show, forKey: Self.key)
        apply()
    }

    func apply() { setPolicy(showInDock ? .regular : .accessory) }
}
