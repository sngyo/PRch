import SwiftUI
import ReviewCore

@main
struct PRchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            ReviewPanel(store: delegate.store, openWindow: { delegate.openWindow() })
        } label: {
            MenuStatusLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuStatusLabel: View {
    @ObservedObject var store: AppStore
    var body: some View {
        HStack(spacing: 4) {
            if store.error != nil {
                BrandMark()
                Image(systemName: "exclamationmark.circle")
            } else {
                MenuBarIndicator(style: store.menuBarStyle, reviews: store.pendingCount, changes: store.changesRequestedCount)
            }
        }.help(store.menuBarSummary).accessibilityLabel(store.menuBarSummary)
    }
}

/// First launch offers a visible setup window. Later launches stay in the menu bar;
/// reopening the app from Finder presents the same panel in a regular window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore(isDemo: ProcessInfo.processInfo.arguments.contains("--demo"))
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !store.scope.isValid || ProcessInfo.processInfo.arguments.contains("--window") {
            openWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }

    func openWindow() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 624),
                                 styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            panel.title = "PRch"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: ReviewPanel(store: store, openWindow: { [weak self] in self?.openWindow() }))
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
