import AppKit
import ApplicationServices
import SwiftUI
import SwiftData
import XCTest
@testable import PetChat

@MainActor
final class PetPanelTests: XCTestCase {
    func testSummonFocusesComposerAndEscapeAndClosePreserveDraft() async throws {
        let model = try makeModel()
        let controller = PetPanelController(model: model, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { controller.hidePet() }
        controller.showPetOnly()
        XCTAssertEqual(controller.petPanel.frame.size, CGSize(width: 64, height: 64))
        XCTAssertFalse(controller.chatPanel.isVisible)
        model.draft = "Keep this question"
        controller.showChat()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(controller.chatPanel.isVisible)
        XCTAssertTrue(controller.chatPanel.firstResponder is NSTextView)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: controller.chatPanel.windowNumber, context: nil,
                                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                   isARepeat: false, keyCode: 53))
        controller.chatPanel.sendEvent(escape)
        XCTAssertFalse(controller.chatPanel.isVisible)
        XCTAssertEqual(model.draft, "Keep this question")
        controller.showChat()
        controller.chatPanel.close()
        XCTAssertFalse(controller.chatPanel.isVisible)
        XCTAssertEqual(model.draft, "Keep this question")
    }

    func testCaptureHidesBothPanelsAndRestoresOnSuccessCancelAndError() async throws {
        let controller = PetPanelController(model: try makeModel(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { controller.hidePet() }
        for outcome in 0...2 {
            controller.showChat()
            do {
                _ = try await controller.captureRegion(using: {
                    XCTAssertFalse(controller.petPanel.isVisible)
                    XCTAssertFalse(controller.chatPanel.isVisible)
                    if outcome == 2 { throw CancellationError() }
                    return outcome == 0 ? testPNG() : nil
                })
            } catch { XCTAssertEqual(outcome, 2) }
            XCTAssertTrue(controller.petPanel.isVisible)
            XCTAssertTrue(controller.chatPanel.isVisible)
        }
    }

    func testCaptureRestoresVisibilityWithoutTakingFocusAfterDeactivation() async throws {
        let controller = PetPanelController(model: try makeModel(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { controller.hidePet() }
        controller.showChat()
        _ = try await controller.captureRegion(using: {
            controller.applicationDidDeactivate()
            return nil
        })
        XCTAssertTrue(controller.chatPanel.isVisible)
        XCTAssertFalse(controller.chatPanel.isKeyWindow)
    }

    func testCaptureDoesNotReopenPanelsAfterExplicitHide() async throws {
        let controller = PetPanelController(model: try makeModel(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { controller.hidePet() }
        controller.showChat()
        _ = try await controller.captureRegion(using: {
            controller.hidePet()
            return testPNG()
        })
        XCTAssertFalse(controller.petPanel.isVisible)
        XCTAssertFalse(controller.chatPanel.isVisible)
    }

    func testAppSwitchDoesNotResummonOrRetakeFocus() throws {
        let controller = PetPanelController(model: try makeModel(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { controller.hidePet() }
        controller.showChat()
        controller.applicationDidDeactivate()
        XCTAssertFalse(controller.chatPanel.isKeyWindow)
        XCTAssertTrue(controller.chatPanel.isVisible)
    }

    func testFullScreenHidesUntilExplicitSummonThenResetsOnSpaceChange() throws {
        let controller = PetPanelController(model: try makeModel(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { controller.hidePet() }
        controller.showPetOnly()
        controller.activeSpaceDidChange(isFullScreen: true)
        XCTAssertFalse(controller.petPanel.isVisible)
        controller.showChat()
        XCTAssertTrue(controller.petPanel.isVisible)
        XCTAssertTrue(controller.chatPanel.isVisible)
        controller.activeSpaceDidChange(isFullScreen: true)
        XCTAssertFalse(controller.petPanel.isVisible)
        XCTAssertFalse(controller.chatPanel.isVisible)
        controller.activeSpaceDidChange(isFullScreen: false)
        XCTAssertTrue(controller.petPanel.isVisible)
        XCTAssertFalse(controller.chatPanel.isVisible)
    }

    func testChangingDesktopToFullScreenDisplayHidesUntilSummoned() throws {
        let panel = PetPanelController(model: try makeModel(), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                       displayProvider: { self.twoDisplays }, fullScreenProvider: { $0 == 2 })
        defer { panel.hidePet() }
        panel.showChat()
        panel.repositionPet(for: 2)
        XCTAssertFalse(panel.petPanel.isVisible)
        XCTAssertFalse(panel.chatPanel.isVisible)
        panel.showChat()
        XCTAssertTrue(panel.petPanel.isVisible)
        XCTAssertTrue(panel.chatPanel.isVisible)
        panel.collapseChat(preservingDraft: true)
        XCTAssertFalse(panel.petPanel.isVisible)
    }

    func testChangingFullScreenToDesktopDisplayRestoresPetOnly() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(2, forKey: "PetChat.selectedDisplayID")
        let panel = PetPanelController(model: try makeModel(), defaults: defaults,
                                       displayProvider: { self.twoDisplays }, fullScreenProvider: { $0 == 2 })
        defer { panel.hidePet() }
        panel.showPetOnly()
        XCTAssertFalse(panel.petPanel.isVisible)
        panel.repositionPet(for: 1)
        XCTAssertTrue(panel.petPanel.isVisible)
        XCTAssertFalse(panel.chatPanel.isVisible)
    }

    func testFullScreenSummonDoesNotCarryToAnotherSelectedDisplay() throws {
        let panel = PetPanelController(model: try makeModel(), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                       displayProvider: { self.twoDisplays }, fullScreenProvider: { _ in true })
        defer { panel.hidePet() }
        panel.showChat()
        XCTAssertTrue(panel.petPanel.isVisible)
        panel.repositionPet(for: 2)
        XCTAssertFalse(panel.petPanel.isVisible)
        XCTAssertFalse(panel.chatPanel.isVisible)
    }

    func testOpenSettingsRefreshesDisplayListAndSelectionAfterDisconnect() async throws {
        var displays = twoDisplays
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(2, forKey: "PetChat.selectedDisplayID")
        let panel = PetPanelController(model: try makeModel(), defaults: defaults,
                                       displayProvider: { displays }, fullScreenProvider: { _ in false })
        defer { panel.hidePet() }
        let shortcut = GlobalShortcutController(defaults: defaults, onSummon: {})
        let host = NSHostingView(rootView: SettingsView(shortcutController: shortcut, panelController: panel))
        host.frame = CGRect(x: 0, y: 0, width: 440, height: 230)
        let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(accessibilityText(in: AXUIElementCreateApplication(getpid())).contains("Second display"))
        displays = [twoDisplays[0]]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(panel.selectedDisplayID, 1)
        let text = accessibilityText(in: AXUIElementCreateApplication(getpid()))
        XCTAssertTrue(text.contains("First display"))
        XCTAssertFalse(text.contains("Second display"))
    }

    private var twoDisplays: [PetDisplay] {
        [PetDisplay(id: 1, visibleFrame: CGRect(x: 0, y: 40, width: 1000, height: 700), name: "First display"),
         PetDisplay(id: 2, visibleFrame: CGRect(x: 1000, y: 40, width: 1000, height: 700), name: "Second display")]
    }

    private func accessibilityText(in element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 20 else { return [] }
        var result: [String] = []
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let value = value as? String { result.append(value) }
        }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let children = children as? [AXUIElement] {
            result += children.flatMap { accessibilityText(in: $0, depth: depth + 1) }
        }
        return result
    }

    func testDraggedPositionPersistsBySelectedDisplayAndClamps() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = try makeModel()
        let controller = PetPanelController(model: model, defaults: defaults)
        defer { controller.hidePet() }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let id = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        controller.repositionPet(for: id)
        controller.movePet(to: CGPoint(x: screen.visibleFrame.maxX + 100, y: screen.visibleFrame.minY - 100))
        XCTAssertEqual(controller.petPanel.frame.origin, CGPoint(x: screen.visibleFrame.maxX - 64, y: screen.visibleFrame.minY))
        let restored = PetPanelController(model: model, defaults: defaults)
        defer { restored.hidePet() }
        XCTAssertEqual(restored.petPanel.frame.origin, controller.petPanel.frame.origin)
    }

    func testMenuHideShowSettingsAndQuitActions() throws {
        let panel = PetPanelController(model: try makeModel(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { panel.hidePet() }
        var settingsOpened = false, quitRequested = false
        let menu = MenuBarController(panel: panel, onSettings: { settingsOpened = true }, onQuit: { quitRequested = true })
        menu.menuWillOpen(menu.menu)
        XCTAssertEqual(menu.menu.items.map(\.title), ["Hide Pet", "Settings…", "", "Quit Pet Chat"])
        menu.menu.performActionForItem(at: 0)
        XCTAssertFalse(panel.petPanel.isVisible)
        menu.menuWillOpen(menu.menu)
        XCTAssertEqual(menu.menu.items[0].title, "Show Pet")
        menu.menu.performActionForItem(at: 0)
        XCTAssertTrue(panel.petPanel.isVisible)
        menu.menu.performActionForItem(at: 1)
        menu.menu.performActionForItem(at: 3)
        XCTAssertTrue(settingsOpened)
        XCTAssertTrue(quitRequested)
    }

    func testRecorderCapturesReplacementAndEscapeCancels() throws {
        var recorded: Shortcut?
        let recorder = ShortcutRecorderButton(shortcut: .default, onRecord: { recorded = $0 })
        recorder.performClick(nil)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        recorder.keyDown(with: escape)
        XCTAssertNil(recorded)
        XCTAssertEqual(recorder.title, "⌃⌥Space")
        recorder.performClick(nil)
        let replacement = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option, .shift],
                                                        timestamp: 0, windowNumber: 0, context: nil, characters: "x",
                                                        charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        recorder.keyDown(with: replacement)
        XCTAssertEqual(recorded, Shortcut(keyCode: 7, modifiers: 4096 | 2048 | 512))
    }

    func testDesktopLaunchIsPetOnlyAndDoesNotLoadModelsUntilSummoned() async throws {
        let provider = PanelTestProvider()
        let delegate = AppDelegate()
        let model = try makeModel(provider: provider)
        delegate.startDesktop(model: model, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let panel = try XCTUnwrap(delegate.panelController)
        defer { panel.hidePet() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(panel.petPanel.isVisible)
        XCTAssertFalse(panel.chatPanel.isVisible)
        let idleCatalogCalls = await provider.catalogCalls
        XCTAssertEqual(idleCatalogCalls, 0)
        panel.showChat()
        try await Task.sleep(for: .milliseconds(200))
        let summonedCatalogCalls = await provider.catalogCalls
        XCTAssertEqual(summonedCatalogCalls, 1)
    }

    func testFinishingSetupFocusesComposer() async throws {
        let model = try makeModel(selectModel: false)
        let panel = PetPanelController(model: model, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { panel.hidePet() }
        panel.showChat()
        try await Task.sleep(for: .milliseconds(150))
        try model.select(providerID: .ollama, modelID: "test")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(panel.chatPanel.firstResponder is NSTextView)
    }

    private func makeModel(provider: PanelTestProvider = PanelTestProvider(), selectModel: Bool = true) throws -> AppModel {
        let attachments = AttachmentStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try LocalChatStore(container: container, attachments: attachments)
        let coordinator = try ChatCoordinator(providers: [.ollama: provider], store: store, attachments: attachments)
        let model = AppModel(coordinator: coordinator, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        if selectModel { try model.select(providerID: .ollama, modelID: "test") }
        return model
    }
}

private actor PanelTestProvider: ChatProvider {
    let providerID: ProviderID = .ollama
    private(set) var catalogCalls = 0
    func availableModels() async throws -> [ProviderModel] { catalogCalls += 1; return [] }
    nonisolated func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancel(_ requestID: UUID) async {}
}
