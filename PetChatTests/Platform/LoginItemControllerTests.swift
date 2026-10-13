import ServiceManagement
import XCTest
@testable import PetChat

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testLaunchDefaultsOffAndNeverRegistersFromSavedOptIn() throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var registrations = 0
        let controller = LoginItemController(defaults: defaults, status: { .notRegistered },
                                             register: { registrations += 1 }, unregister: {})
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.optedIn)
        defaults.set(true, forKey: "PetChat.launchAtLogin")
        let restored = LoginItemController(defaults: defaults, status: { .notRegistered },
                                           register: { registrations += 1 }, unregister: {})
        XCTAssertTrue(restored.optedIn)
        XCTAssertFalse(restored.isEnabled)
        XCTAssertEqual(registrations, 0)
    }

    func testOnlyExplicitToggleRegistersAndPersistsOptIn() throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var status = SMAppService.Status.notRegistered
        let controller = LoginItemController(defaults: defaults, status: { status },
                                             register: { status = .enabled }, unregister: { status = .notRegistered })
        try controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: "PetChat.launchAtLogin"))
        try controller.setEnabled(false)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: "PetChat.launchAtLogin"))
    }

    func testDisablingRemovedLoginItemClearsSavedOptIn() throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "PetChat.launchAtLogin")
        let controller = LoginItemController(defaults: defaults, status: { .notRegistered },
            register: { throw CocoaError(.fileWriteNoPermission) },
            unregister: { throw CocoaError(.fileNoSuchFile) })
        try controller.setEnabled(false)
        XCTAssertFalse(controller.optedIn)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: "PetChat.launchAtLogin"))
    }

    func testRequiresApprovalIsNotEnabledAndFailureKeepsPriorChoice() throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var status = SMAppService.Status.notRegistered
        let controller = LoginItemController(defaults: defaults, status: { status },
                                             register: { status = .requiresApproval },
                                             unregister: { throw CocoaError(.fileWriteNoPermission) })
        try controller.setEnabled(true)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)
        XCTAssertTrue(controller.optedIn)
        XCTAssertThrowsError(try controller.setEnabled(false))
        XCTAssertTrue(controller.optedIn)
        XCTAssertTrue(defaults.bool(forKey: "PetChat.launchAtLogin"))
    }
}
