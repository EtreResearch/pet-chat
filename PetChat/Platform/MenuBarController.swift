import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: PetPanelController
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    init(panel: PetPanelController, onSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.panel = panel
        self.onSettings = onSettings
        self.onQuit = onQuit
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "cat", accessibilityDescription: "Pet Chat")
        statusItem.button?.setAccessibilityLabel("Pet Chat")
        statusItem.button?.setAccessibilityHelp("Show or hide the pet, open Settings, or quit Pet Chat.")
        for (title, action) in [("Hide Pet", #selector(togglePet)), ("Settings…", #selector(settings))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pet Chat", action: #selector(quit), keyEquivalent: "q").target = self
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { menu.items.first?.title = panel.isPetVisible ? "Hide Pet" : "Show Pet" }
    @objc private func togglePet() { if panel.isPetVisible { panel.hidePet() } else { panel.showPetOnly() } }
    @objc private func settings() { onSettings() }
    @objc private func quit() { onQuit() }
    isolated deinit { NSStatusBar.system.removeStatusItem(statusItem) }
}
