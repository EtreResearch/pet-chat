import XCTest

final class AppConfigurationTests: XCTestCase {
    func testScreenCapturePurposeIsPresentInAppBundle() {
        let purpose = Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") as? String
        XCTAssertFalse(purpose?.isEmpty ?? true)
    }

    func testShowsInDockByDefault() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "LSUIElement"))
    }
}
