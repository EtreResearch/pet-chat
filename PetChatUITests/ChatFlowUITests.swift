import XCTest

@MainActor
class IsolatedUITestCase: XCTestCase {
    let app = XCUIApplication()
    var fixtureRoot: URL!
    private var cleanupRequested = false
    var opensChatOnLaunch: Bool { true }

    override func setUp() async throws {
        continueAfterFailure = false
        fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PetChat-UI-\(UUID())")
        app.launchEnvironment["PET_CHAT_UI_ROOT"] = fixtureRoot.path
        app.launchEnvironment["PET_CHAT_UI_OPEN_CHAT"] = opensChatOnLaunch ? "1" : "0"
        app.launch()
    }

    override func tearDown() async throws {
        guard !cleanupRequested else { return }
        cleanupRequested = true
        defer { app.terminate() }
        app.terminate()
        let domain = "PetChat.UI.\(fixtureRoot.lastPathComponent)"
        app.launchEnvironment["PET_CHAT_UI_CLEANUP"] = "1"
        app.launch()
        let receipt = fixtureRoot.appendingPathComponent("cleanup-complete")
        let cleaned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: receipt.path)
        }, object: nil)
        await fulfillment(of: [cleaned], timeout: 3)
        app.terminate()
        XCTAssertEqual(try? String(contentsOf: receipt, encoding: .utf8), domain)
        try FileManager.default.removeItem(at: fixtureRoot)
    }

    func openChat() {
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 3))
    }

    func summonChat() {
        let pet = app.buttons["Pet"]
        XCTAssertTrue(pet.waitForExistence(timeout: 5))
        pet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        openChat()
    }

    func chooseModel(provider: String = "Ollama") {
        app.popUpButtons["Provider"].click()
        app.menuItems[provider].click()
        let model = app.popUpButtons["Model"]
        XCTAssertTrue(model.waitForExistence(timeout: 3))
        model.click()
        let choice = app.menuItems["Fixture model"]
        XCTAssertTrue(choice.waitForExistence(timeout: 3))
        choice.click()
        XCTAssertTrue(app.buttons["Start chatting"].isEnabled)
        app.buttons["Start chatting"].click()
        XCTAssertTrue(app.textViews["Message"].waitForExistence(timeout: 3))
    }

    func send(_ text: String) {
        app.textViews["Message"].click()
        app.textViews["Message"].typeText(text)
        app.buttons["Send"].click()
    }

    func text(_ value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    func binding(_ value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", value, value)).firstMatch
    }

    func snapshot(_ name: String, of element: XCUIElement) throws {
        let screenshot = element.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PetChat-task10-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name + ".png")
        try screenshot.pngRepresentation.write(to: path)
        print("Window-only synthetic screenshot: \(path.path)")
    }
}

final class ChatFlowUITests: IsolatedUITestCase {
    func testLaunchUsesIsolatedStorage() {
        XCTAssertTrue(app.descendants(matching: .any)["Pet"].waitForExistence(timeout: 5))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureRoot.appendingPathComponent("history.store").path))
    }

    func testTextFollowUpExpansionAndEscapeRetainDraft() throws {
        openChat()
        chooseModel()
        send("Hello pet")
        XCTAssertTrue(text("Answer 1: Hello pet").waitForExistence(timeout: 5))
        send("Follow up")
        XCTAssertTrue(text("Answer 3: Follow up").waitForExistence(timeout: 5))
        app.buttons["Tell me more"].click()
        XCTAssertTrue(text("Answer 5:").waitForExistence(timeout: 5))
        try snapshot("conversation", of: app.windows["Pet Chat"])
        app.textViews["Message"].click()
        app.textViews["Message"].typeText("Keep this draft")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons["Close"].exists)
        summonChat()
        XCTAssertEqual(app.textViews["Message"].value as? String, "Keep this draft")
    }

    func testStopAndRetry() {
        openChat()
        chooseModel()
        send("Wait please")
        XCTAssertTrue(text("Working slowly").waitForExistence(timeout: 5))
        app.buttons["Stop"].click()
        XCTAssertTrue(text("Stopped").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Send"].isEnabled)
        app.textViews["Message"].click()
        app.typeKey("a", modifierFlags: .command)
        app.textViews["Message"].typeText("Retry please")
        app.buttons["Send"].click()
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
        app.buttons["Retry"].click()
        XCTAssertTrue(text("Answer 1: Retry please").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Tell me more"].isEnabled)
    }

    func testCapturePreviewRemoveExplicitSendRestartAndDelete() throws {
        openChat()
        chooseModel()
        app.buttons["Capture area"].click()
        XCTAssertTrue(app.buttons["Remove image"].waitForExistence(timeout: 3))
        XCTAssertFalse(text("Answer").exists)
        try snapshot("capture-preview", of: app.windows["Pet Chat"])
        app.buttons["Remove image"].click()
        XCTAssertFalse(app.buttons["Remove image"].exists)
        app.buttons["Capture area"].click()
        XCTAssertTrue(app.buttons["Remove image"].waitForExistence(timeout: 3))
        app.buttons["Send"].click()
        XCTAssertTrue(text("1 image received").waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        openChat()
        XCTAssertTrue(text("1 image received").waitForExistence(timeout: 3))
        XCTAssertTrue(binding("Ollama · fixture-model").exists)
        let attachments = fixtureRoot.appendingPathComponent("Attachments")
        let firstDirectories = try FileManager.default.contentsOfDirectory(atPath: attachments.path)
            .filter { UUID(uuidString: $0) != nil }
        XCTAssertEqual(firstDirectories.count, 1)
        app.menuButtons["Chat"].click()
        app.menuItems["New Chat"].click()
        XCTAssertFalse(text("1 image received").exists)
        app.buttons["Capture area"].click()
        XCTAssertTrue(app.buttons["Remove image"].waitForExistence(timeout: 3))
        app.buttons["Send"].click()
        XCTAssertTrue(text("1 image received").waitForExistence(timeout: 5))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: attachments.path)
            .filter { UUID(uuidString: $0) != nil }.count, 2)
        app.menuButtons["Chat"].click()
        app.menuItems["Delete Chat"].click()
        XCTAssertTrue(text("1 image received").waitForExistence(timeout: 3))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: attachments.path)
            .filter { UUID(uuidString: $0) != nil }
        XCTAssertEqual(remaining, firstDirectories)
    }

    func testProviderChangeStartsBoundNewChatAndRestoresIt() {
        openChat()
        chooseModel()
        send("Local conversation")
        XCTAssertTrue(text("Answer 1: Local conversation").waitForExistence(timeout: 5))
        app.menuButtons["Chat"].click()
        app.menuItems["Change model"].click()
        chooseModel(provider: "ChatGPT")
        XCTAssertFalse(text("Local conversation").exists)
        XCTAssertTrue(binding("ChatGPT · fixture-model").exists)
        send("Remote fixture")
        XCTAssertTrue(text("Answer 1: Remote fixture").waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        openChat()
        XCTAssertTrue(binding("ChatGPT · fixture-model").exists)
        XCTAssertTrue(text("Answer 1: Remote fixture").exists)
        app.menuButtons["Chat"].click()
        app.menuItems["Delete Chat"].click()
        XCTAssertTrue(text("Answer 1: Local conversation").waitForExistence(timeout: 3))
    }

    func testSetupAndSettingsControls() throws {
        openChat()
        let login = app.checkBoxes["Launch at login"]
        XCTAssertTrue(login.exists)
        XCTAssertEqual(login.value as? Int, 0)
        login.click()
        XCTAssertEqual(login.value as? Int, 1)
        chooseModel()
        send("Large type")
        XCTAssertTrue(text("Answer 1: Large type").waitForExistence(timeout: 5))
        app.menuBars.statusItems["Pet Chat"].click()
        app.menuBars.statusItems["Pet Chat"].menuItems["Settings…"].click()
        let window = app.windows["Pet Chat Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        XCTAssertEqual(window.checkBoxes["Launch at login"].value as? Int, 1)
        window.checkBoxes["Launch at login"].click()
        window.popUpButtons["Text size"].click()
        app.menuItems["Larger (17 pt)"].click()
        XCTAssertTrue(window.buttons["Open chat shortcut"].exists)
        XCTAssertTrue(window.popUpButtons["Pet display"].exists)
        window.buttons["Sign out of ChatGPT"].click()
        try snapshot("settings", of: window)
        window.buttons[XCUIIdentifierCloseWindow].click()
        try snapshot("larger-conversation", of: app.windows["Pet Chat"])
        app.terminate()
        app.launch()
        openChat()
        XCTAssertTrue(app.textViews["Message"].exists)
        XCTAssertTrue(text("Answer 1: Large type").exists)
        app.menuBars.statusItems["Pet Chat"].click()
        app.menuBars.statusItems["Pet Chat"].menuItems["Settings…"].click()
        let restored = app.windows["Pet Chat Settings"]
        XCTAssertTrue(restored.waitForExistence(timeout: 3))
        XCTAssertEqual(restored.checkBoxes["Launch at login"].value as? Int, 0)
        XCTAssertEqual(restored.popUpButtons["Text size"].value as? String, "Larger (17 pt)")
    }
}
