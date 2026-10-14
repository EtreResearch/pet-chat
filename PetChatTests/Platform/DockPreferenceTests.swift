import XCTest
@testable import PetChat

@MainActor final class DockPreferenceTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "DockPreferenceTests-\(UUID())")!
        return d
    }
    func testDefaultsToShowingInDock() {
        var applied: [NSApplication.ActivationPolicy] = []
        let pref = DockPreference(defaults: defaults(), setPolicy: { applied.append($0) })
        pref.apply()
        XCTAssertTrue(pref.showInDock)
        XCTAssertEqual(applied, [.regular])
    }
    func testTogglingAppliesPolicyImmediately() {
        var applied: [NSApplication.ActivationPolicy] = []
        let pref = DockPreference(defaults: defaults(), setPolicy: { applied.append($0) })
        pref.setShowInDock(false)
        pref.setShowInDock(true)
        XCTAssertEqual(applied, [.accessory, .regular])
    }
    func testSettingPersists() {
        let d = defaults()
        DockPreference(defaults: d, setPolicy: { _ in }).setShowInDock(false)
        XCTAssertFalse(DockPreference(defaults: d, setPolicy: { _ in }).showInDock)
    }
}
