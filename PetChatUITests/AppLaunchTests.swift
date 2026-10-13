import XCTest

final class AppLaunchTests: IsolatedUITestCase {
    override var opensChatOnLaunch: Bool { false }
    @MainActor
    func testAppLaunchesWithPetVisible() throws {

        XCTAssertTrue(app.buttons["Pet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pet"].isHittable)
    }
}
