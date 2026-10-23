import ServiceManagement
import Testing
@testable import PRch

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    var status = SMAppService.Status.notRegistered
    var statusAfterRegister = SMAppService.Status.enabled
    var fails = false
    var registrationCount = 0
    var unregistrationCount = 0
    private struct Failure: Error {}

    func register() throws {
        registrationCount += 1
        if fails { throw Failure() }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregistrationCount += 1
        if fails { throw Failure() }
        status = .notRegistered
    }
}

@Test @MainActor func loginItemReadsSystemStateWithoutRegisteringOnLaunch() {
    let service = FakeLoginItemService()
    service.status = .enabled
    let settings = LoginItemSettings(service: service, isAvailable: true)
    #expect(settings.isOn)
    #expect(service.registrationCount == 0 && service.unregistrationCount == 0)

    service.status = .notRegistered
    settings.refresh()
    #expect(!settings.isOn)
    service.status = .requiresApproval
    settings.refresh()
    #expect(settings.isOn && settings.status == .requiresApproval)
    service.status = .notFound
    settings.refresh()
    #expect(!settings.isOn)
}

@Test @MainActor func loginItemRegistersAndUnregistersUsingFreshSystemState() {
    let service = FakeLoginItemService()
    let settings = LoginItemSettings(service: service, isAvailable: true)
    settings.setEnabled(true)
    #expect(settings.isOn && settings.errorKey == nil)
    #expect(service.registrationCount == 1)
    #expect(LoginItemSettings(service: service, isAvailable: true).isOn)

    // Repeated requests and changes made outside the app must not register twice.
    settings.setEnabled(true)
    #expect(service.registrationCount == 1)
    service.status = .notRegistered
    settings.setEnabled(false)
    #expect(!settings.isOn && service.unregistrationCount == 0)
    service.status = .enabled
    settings.setEnabled(false)
    #expect(!settings.isOn && settings.errorKey == nil)
    #expect(service.unregistrationCount == 1)
}

@Test @MainActor func loginItemPendingApprovalCanBeCancelled() {
    let service = FakeLoginItemService()
    service.statusAfterRegister = .requiresApproval
    let settings = LoginItemSettings(service: service, isAvailable: true)
    settings.setEnabled(true)
    #expect(settings.isOn && settings.status == .requiresApproval)
    #expect(settings.errorKey == nil)
    settings.setEnabled(false)
    #expect(!settings.isOn && service.unregistrationCount == 1)
}

@Test @MainActor func loginItemFailuresPreserveActualStateAndAllowRetry() {
    let service = FakeLoginItemService()
    let settings = LoginItemSettings(service: service, isAvailable: true)
    service.fails = true
    settings.setEnabled(true)
    #expect(!settings.isOn && settings.errorKey == "loginItem.enableFailed")
    service.fails = false
    settings.setEnabled(true)
    #expect(settings.isOn && settings.errorKey == nil)
    service.fails = true
    settings.setEnabled(false)
    #expect(settings.isOn && settings.errorKey == "loginItem.disableFailed")

    // Resolving the problem in System Settings clears the stale error.
    service.status = .notRegistered
    settings.refresh()
    #expect(!settings.isOn && settings.errorKey == nil)
}

@Test @MainActor func loginItemDoesNotRegisterOutsideAnAppBundle() {
    let service = FakeLoginItemService()
    let settings = LoginItemSettings(service: service, isAvailable: false)
    settings.setEnabled(true)
    #expect(!settings.isOn && settings.errorKey == nil)
    #expect(service.registrationCount == 0 && service.unregistrationCount == 0)
}
