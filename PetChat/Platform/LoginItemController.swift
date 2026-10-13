import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
final class LoginItemController {
    private let defaults: UserDefaults
    private let status: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private(set) var optedIn: Bool
    private var serviceStatus: SMAppService.Status
    var isEnabled: Bool { serviceStatus == .enabled }
    var requiresApproval: Bool { serviceStatus == .requiresApproval }

    init(defaults: UserDefaults = .standard, status: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }) {
        self.defaults = defaults
        self.status = status
        self.register = register
        self.unregister = unregister
        optedIn = defaults.bool(forKey: "PetChat.launchAtLogin")
        serviceStatus = status()
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled { try register() }
        else if [.enabled, .requiresApproval].contains(status()) { try unregister() }
        optedIn = enabled
        defaults.set(enabled, forKey: "PetChat.launchAtLogin")
        refreshStatus()
    }

    func refreshStatus() {
        serviceStatus = status()
    }
}
