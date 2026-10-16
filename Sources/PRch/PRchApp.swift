import SwiftUI
import ReviewCore

@main
enum PRchApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

/// First launch offers a visible setup window. Later launches stay in the menu bar;
/// reopening the app from Finder presents the same panel in a regular window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore(isDemo: ProcessInfo.processInfo.arguments.contains("--demo"),
                         demoActivity: ProcessInfo.processInfo.arguments.contains("--demo-activity"))
    private var window: NSWindow?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(store: store, openWindow: { [weak self] in self?.openWindow() })
        if !store.scope.isValid || ProcessInfo.processInfo.arguments.contains("--window") {
            openWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return false
    }

    func openWindow() {
        menuBar?.closePanel()
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(origin: .zero, size: PanelLayout.size),
                                 styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            panel.title = "PRch"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: ReviewPanel(store: store))
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
