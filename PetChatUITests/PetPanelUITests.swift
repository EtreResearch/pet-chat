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
        close.click()
        XCTAssertFalse(close.exists)
        XCTAssertTrue(pet.exists)
    }
}
