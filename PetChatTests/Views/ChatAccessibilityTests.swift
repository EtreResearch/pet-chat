import AppKit
import ApplicationServices
import SwiftData
import SwiftUI
import XCTest
@testable import PetChat

@MainActor
final class ChatAccessibilityTests: XCTestCase {
    func testChatPanelLabelsPetComposerAndActions() async throws {
        let attachments = AttachmentStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: attachments.root) }
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try LocalChatStore(container: container, attachments: attachments)
        let coordinator = try ChatCoordinator(providers: [.ollama: AccessibilityProvider()], store: store,
                                              attachments: attachments)
        let model = AppModel(coordinator: coordinator, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try model.select(providerID: .ollama, modelID: "test")
        try model.attachImage(testPNG())
        model.draft = "What is in this picture?"
        let hosting = NSHostingView(rootView: VStack(spacing: 0) {
            ChatPanelView(model: model, onClose: {}, onChangeModel: {})
            PetCharacterView()
        })
        hosting.frame = CGRect(x: 0, y: 0, width: 440, height: 594)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()

        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let labels = accessibilityLabels(in: AXUIElementCreateApplication(getpid()))
        for label in ["Pet", "Message", "Send", "Stop", "Tell me more", "Close", "Capture area", "Paste image", "Attached image", "Remove image"] {
            XCTAssertTrue(labels.contains(label), "Missing accessible \(label): \(labels)")
        }
    }

    func testSetupExposesLoginConsentAndPrivacyExplanation() async throws {
        let model = try makeSettingsModel()
        let host = NSHostingView(rootView: SetupView(model: model, onSelected: {}))
        host.frame = CGRect(x: 0, y: 0, width: 340, height: 420)
        let window = show(host)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let labels = accessibilityLabels(in: AXUIElementCreateApplication(getpid()))
        for label in ["Provider", "Model", "Launch at login", "Start chatting"] {
            XCTAssertTrue(labels.contains(label), "Missing accessible \(label): \(labels)")
        }
        XCTAssertTrue(labels.contains { $0.contains("Send") && $0.localizedCaseInsensitiveContains("image") })
    }

    func testSettingsExposesSavedProviderSignOutAndPermissionRecovery() async throws {
        let model = try makeSettingsModel()
        try model.select(providerID: .ollama, modelID: "test")
        let panel = PetPanelController(model: model, defaults: UserDefaults(suiteName: UUID().uuidString)!,
            fullScreenProvider: { _ in false })
        defer { panel.hidePet() }
        let shortcuts = GlobalShortcutController(defaults: UserDefaults(suiteName: UUID().uuidString)!, onSummon: {})
        let host = NSHostingView(rootView: SettingsView(shortcutController: shortcuts, panelController: panel))
        host.frame = CGRect(x: 0, y: 0, width: 440, height: 620)
        let window = show(host)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let labels = accessibilityLabels(in: AXUIElementCreateApplication(getpid()))
        for label in ["Launch at login", "Sign out of ChatGPT", "Open chat shortcut", "Pet display", "Text size"] {
            XCTAssertTrue(labels.contains(label), "Missing accessible \(label): \(labels)")
        }
        XCTAssertTrue(labels.contains { $0.contains("Screen Recording") && $0.contains("System Settings") })
        XCTAssertTrue(labels.contains { $0.contains("Ollama") && $0.contains("test") })
    }

    func testLargerTextScalesComposerFontAndEditorWithinPanel() async throws {
        let model = try makeSettingsModel()
        try model.select(providerID: .ollama, modelID: "test")
        func measure(_ size: Double) async throws -> (font: CGFloat, height: CGFloat) {
            model.textSize = size
            let host = NSHostingView(rootView: ChatPanelView(model: model, onClose: {}, onChangeModel: {}))
            host.frame = CGRect(x: 0, y: 0, width: 440, height: 530)
            let window = show(host)
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(100))
            func editor(in view: NSView) -> NSTextView? {
                if let text = view as? NSTextView { return text }
                return view.subviews.lazy.compactMap { editor(in: $0) }.first
            }
            let text = try XCTUnwrap(editor(in: host))
            let viewport = try XCTUnwrap(text.enclosingScrollView)
            XCTAssertTrue(host.bounds.contains(viewport.convert(viewport.bounds, to: host)))
            return (try XCTUnwrap(text.font).pointSize, viewport.frame.height)
        }
        let standard = try await measure(13)
        let larger = try await measure(17)
        XCTAssertGreaterThan(larger.font, standard.font)
        XCTAssertGreaterThan(larger.height, standard.height)
    }

    func testThinkingPetKeepsAccessibleNameAndCompactSize() async throws {
        let host = NSHostingView(rootView: PetCharacterView(isThinking: true))
        host.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        let window = show(host)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(accessibilityLabels(in: AXUIElementCreateApplication(getpid())).contains("Pet, thinking"))
        XCTAssertEqual(host.fittingSize.width, 64, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, 64, accuracy: 1)
    }

    private func makeSettingsModel() throws -> AppModel {
        let attachments = AttachmentStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let coordinator = try ChatCoordinator(providers: [.ollama: AccessibilityProvider()],
            store: LocalChatStore(container: container, attachments: attachments), attachments: attachments)
        return AppModel(coordinator: coordinator,
            auth: ChatGPTOAuthClient(store: KeychainCredentialStore(service: "com.etre.pet-chat.accessibility-tests.\(UUID())")),
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func show(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        return window
    }

    func testStreamingReplyDoesNotAnnounceInterrupted() {
        let row = NSHostingView(rootView: MessageRowView(
            message: ChatMessage(role: .pet, text: "Partial", status: .failed),
            outsideContext: false, isStreaming: true))
        row.frame = CGRect(x: 0, y: 0, width: 300, height: 80)
        let window = NSWindow(contentRect: row.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = row
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        row.layoutSubtreeIfNeeded()

        let labels = accessibilityLabels(in: AXUIElementCreateApplication(getpid()))
        XCTAssertTrue(labels.contains { $0.contains("Partial") })
        XCTAssertFalse(labels.contains { $0.contains("Interrupted") })
    }

    private func accessibilityLabels(in element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 20 else { return [] }
        var labels: [String] = []
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let text = value as? String { labels.append(text) }
        }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let items = children as? [AXUIElement] {
            labels += items.flatMap { accessibilityLabels(in: $0, depth: depth + 1) }
        }
        return labels
    }
}

private struct AccessibilityProvider: ChatProvider {
    func availableModels() async throws -> [ProviderModel] { [] }
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancel(_ requestID: UUID) async {}
}
