import AppKit
import Carbon
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    let shortcutController: GlobalShortcutController
    let panelController: PetPanelController
    @State private var shortcut: Shortcut
    @State private var error: String?
    @State private var displayID: CGDirectDisplayID
    @State private var displays: [PetDisplay]

    init(shortcutController: GlobalShortcutController, panelController: PetPanelController, initialError: String? = nil) {
        self.shortcutController = shortcutController
        self.panelController = panelController
        _shortcut = State(initialValue: shortcutController.shortcut ?? GlobalShortcutController.savedShortcut())
        _error = State(initialValue: initialError)
        _displayID = State(initialValue: panelController.selectedDisplayID ?? 0)
        _displays = State(initialValue: panelController.displays)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LoginItemControl(controller: panelController.model.loginItemController)
                Divider()
                HStack {
                    Text("Open chat")
                    Spacer()
                    ShortcutRecorder(shortcut: shortcut) { candidate in
                        do {
                            try shortcutController.register(candidate)
                            shortcut = candidate
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                    .frame(width: 170, height: 28)
                }
                Text("Click the shortcut, then press a new combination. Escape cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.primary).accessibilityLabel(error) }
                Picker("Pet display", selection: $displayID) {
                    ForEach(displays) { display in
                        Text(display.name).tag(display.id)
                    }
                }
                .accessibilityLabel("Pet display")
                .onChange(of: displayID) { _, id in panelController.repositionPet(for: id) }
                Divider()
                Text("Current chat: \(panelController.model.selectedProviderID == .ollama ? "Ollama" : "ChatGPT") · \(panelController.model.selectedModelID)")
                    .textSelection(.enabled)
                Text("Use Chat → Change model to choose a provider and model for a new chat.")
                    .font(.caption)
                Button("Sign out of ChatGPT") { Task { await panelController.model.signOutChatGPT() } }
                    .accessibilityHint("Removes this app’s active ChatGPT credential. Keeps local chats, drafts, and Ollama settings.")
                if let message = panelController.model.errorMessage { Text(message).foregroundStyle(.primary) }
                Divider()
                Text("Images are sent only when you press Send. Capture area asks for Screen Recording permission; Paste image does not need it.")
                    .font(.caption)
                Text(RegionCaptureController.Error.permissionDenied.localizedDescription).font(.caption)
                Button("Screen Recording Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                Text("Pet animations follow macOS Reduce Motion. Text and controls use your system appearance and accessibility settings.")
                    .font(.caption)
            }
            .padding(20)
        }
        .frame(width: 440)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)) { _ in
                displays = panelController.displays
                displayID = panelController.selectedDisplayID ?? 0
            }
    }
}

struct LoginItemControl: View {
    @Bindable var controller: LoginItemController
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at login", isOn: Binding(get: { controller.optedIn }, set: { enabled in
                do { try controller.setEnabled(enabled); error = nil }
                catch { self.error = error.localizedDescription }
            }))
            .accessibilityLabel("Launch at login")
            .accessibilityHint("Optional. Starts Pet Chat when you sign in to your Mac.")
            if controller.requiresApproval {
                Text("Allow Pet Chat in System Settings → General → Login Items to finish enabling launch at login.")
                    .font(.caption)
                Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
            } else if controller.optedIn && !controller.isEnabled {
                Text("Launch at login is unavailable. Turn it off and on to retry registration.").font(.caption)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.primary) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshStatus()
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: Shortcut
    let onRecord: (Shortcut) -> Void
    func makeNSView(context: Context) -> ShortcutRecorderButton {
        ShortcutRecorderButton(shortcut: shortcut, onRecord: onRecord)
    }
    func updateNSView(_ view: ShortcutRecorderButton, context: Context) {
        view.shortcut = shortcut
        view.onRecord = onRecord
        if !view.isRecording { view.title = shortcut.label }
    }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut: Shortcut
    var onRecord: (Shortcut) -> Void
    private(set) var isRecording = false

    init(shortcut: Shortcut, onRecord: @escaping (Shortcut) -> Void) {
        self.shortcut = shortcut
        self.onRecord = onRecord
        super.init(frame: .zero)
        title = shortcut.label
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        setAccessibilityLabel("Open chat shortcut")
        setAccessibilityHelp("Press to record a new shortcut. Escape cancels.")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    @objc private func startRecording() {
        isRecording = true
        title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        isRecording = false
        title = shortcut.label
        guard event.keyCode != UInt16(kVK_Escape) else { return }
        var modifiers: UInt32 = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.command, cmdKey), (.shift, shiftKey)] {
            if event.modifierFlags.contains(flag) { modifiers |= UInt32(carbon) }
        }
        onRecord(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers))
    }
    override func resignFirstResponder() -> Bool {
        isRecording = false
        title = shortcut.label
        return super.resignFirstResponder()
    }
}
