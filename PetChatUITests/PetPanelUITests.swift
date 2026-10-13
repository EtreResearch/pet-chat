import XCTest

final class PetPanelUITests: IsolatedUITestCase {
    override var opensChatOnLaunch: Bool { false }
    @MainActor
    func testPetOpensCompactPanelAndCloseCollapses() {
        let pet = app.descendants(matching: .any)["Pet"]
        XCTAssertTrue(pet.waitForExistence(timeout: 5))
        XCTAssertEqual(pet.frame.height, 64, accuracy: 2)
        pet.click()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        chooseModel()
        XCTAssertTrue(app.buttons["Capture area"].exists)
        XCTAssertTrue(app.buttons["Paste image"].exists)
        close.click()
        XCTAssertFalse(close.exists)
        XCTAssertTrue(pet.exists)
    }
}
