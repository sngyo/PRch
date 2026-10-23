import ServiceManagement
import SwiftUI

@MainActor
protocol LoginItemServicing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemServicing {}

@MainActor
final class LoginItemSettings: ObservableObject {
    @Published private(set) var status = SMAppService.Status.notRegistered
    @Published private(set) var errorKey: String?
    let isAvailable: Bool
    private let service: any LoginItemServicing

    init(service: (any LoginItemServicing)? = nil,
         isAvailable: Bool = Bundle.main.bundleURL.pathExtension == "app") {
        self.service = service ?? SMAppService.mainApp
        self.isAvailable = isAvailable
        refresh()
    }

    // A pending registration stays selected so the user can cancel it.
    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        guard isAvailable else { return }
        let current = service.status
        if current != status { errorKey = nil }
        status = current
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else { return }
        // System Settings may have changed the registration since the panel opened.
        refresh()
        errorKey = nil
        guard enabled != isOn else { return }
        var failure: String?
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
        } catch {
            failure = enabled ? "loginItem.enableFailed" : "loginItem.disableFailed"
        }
        // macOS is the source of truth, including when an operation fails.
        refresh()
        errorKey = enabled && status == .requiresApproval ? nil : failure
    }
}

struct LoginItemSettingsView: View {
    @StateObject private var settings = LoginItemSettings()
    @Environment(\.l10n) private var l10n
    let isDemo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(l10n.text("loginItem.title"), isOn: Binding(
                get: { settings.isOn }, set: { settings.setEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(isDemo || !settings.isAvailable)
            if isDemo {
                help("loginItem.demo")
            } else if !settings.isAvailable {
                help("loginItem.appRequired")
            } else {
                help("loginItem.help")
                if settings.status == .requiresApproval {
                    help("loginItem.approvalRequired")
                }
                if let errorKey = settings.errorKey {
                    Text(l10n.text(errorKey)).font(.system(size: 12)).foregroundStyle(Palette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if settings.status == .requiresApproval || settings.errorKey != nil {
                    Button(l10n.text("loginItem.openSettings")) {
                        SMAppService.openSystemSettingsLoginItems()
                    }.font(.system(size: 12))
                }
            }
        }
        .onAppear { settings.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }

    private func help(_ key: String) -> some View {
        Text(l10n.text(key)).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
