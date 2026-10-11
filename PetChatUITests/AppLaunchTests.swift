import XCTest

final class AppLaunchTests: XCTestCase {
    @MainActor
    func testAppLaunchesWithPetVisible() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["Pet"].waitForExistence(timeout: 5))
    }
}
