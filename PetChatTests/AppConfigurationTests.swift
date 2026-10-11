import XCTest

final class AppConfigurationTests: XCTestCase {
    func testRunsAsAccessoryApp() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
    }
}
