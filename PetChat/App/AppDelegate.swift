import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var panelController: PetPanelController?
    private var shortcutController: GlobalShortcutController?
    private var menuBarController: MenuBarController?
    private var settingsWindow: NSWindow?
    private var shortcutRegistrationError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let attachments = AttachmentStore()
            let store = try LocalChatStore()
            let auth = ChatGPTOAuthClient()
            let coordinator = try ChatCoordinator(
                providers: [.ollama: OllamaProvider(), .chatGPT: OpenAIPlanProvider(auth: auth)],
                store: store, attachments: attachments)
            startDesktop(model: AppModel(coordinator: coordinator, auth: auth))
        } catch {
            let alert = NSAlert()
            alert.messageText = "Pet Chat could not open local history"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func startDesktop(model: AppModel, defaults: UserDefaults = .standard) {
        guard panelController == nil else { return }
        let panel = PetPanelController(model: model, defaults: defaults)
        panelController = panel
        let shortcut = GlobalShortcutController(defaults: defaults, onSummon: { [weak panel] in panel?.showChat() })
        shortcutController = shortcut
        do { try shortcut.register(GlobalShortcutController.savedShortcut(in: defaults)) }
        catch { shortcutRegistrationError = error.localizedDescription }
        menuBarController = MenuBarController(panel: panel, onSettings: { [weak self] in self?.showSettings() },
                                              onQuit: { NSApp.terminate(nil) })
        panel.showPetOnly()
        if shortcutRegistrationError != nil { showSettings() }
    }

    private func showSettings() {
        guard let shortcutController, let panelController else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 230),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Pet Chat Settings"
            window.contentView = NSHostingView(rootView: SettingsView(shortcutController: shortcutController,
                                                                      panelController: panelController,
                                                                      initialError: shortcutRegistrationError))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
