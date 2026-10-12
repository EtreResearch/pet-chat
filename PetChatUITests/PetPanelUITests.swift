import XCTest

final class PetPanelUITests: XCTestCase {
    @MainActor
    func testPetOpensCompactPanelAndCloseCollapses() {
        let app = XCUIApplication()
        app.launch()
        let pet = app.descendants(matching: .any)["Pet"]
        XCTAssertTrue(pet.waitForExistence(timeout: 5))
        XCTAssertEqual(pet.frame.height, 64, accuracy: 2)
        pet.click()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        // Capture controls exist only after setup; never invoke screen permission in automation.
        if app.textViews["Message"].exists {
            XCTAssertTrue(app.buttons["Capture area"].exists)
            XCTAssertTrue(app.buttons["Paste image"].exists)
        }
        close.click()
        XCTAssertFalse(close.exists)
        XCTAssertTrue(pet.exists)
    }
}
