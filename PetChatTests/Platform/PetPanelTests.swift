import AppKit
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
        controller.chatPanel.cancelOperation(nil)
        XCTAssertFalse(controller.chatPanel.isVisible)
        XCTAssertEqual(model.draft, "Keep this question")
        controller.showChat()
        controller.collapseChat(preservingDraft: true)
        XCTAssertEqual(model.draft, "Keep this question")
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

    private func makeModel(provider: PanelTestProvider = PanelTestProvider()) throws -> AppModel {
        let attachments = AttachmentStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try LocalChatStore(container: container, attachments: attachments)
        let coordinator = try ChatCoordinator(providers: [.ollama: provider], store: store, attachments: attachments)
        let model = AppModel(coordinator: coordinator, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try model.select(providerID: .ollama, modelID: "test")
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
