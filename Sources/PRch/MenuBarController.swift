import AppKit
import Combine
import SwiftUI

/// Owns the status button so primary and secondary clicks can have distinct actions.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: AppStore
    private let openWindow: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var storeSubscription: AnyCancellable?
    private var labelUpdateScheduled = false
    private var lastImageState: MenuBarImageState?
    private var lastSummary: String?
    private var menuLanguage: String?
    private var isRestarting = false

    init(store: AppStore, openWindow: @escaping () -> Void) {
        self.store = store
        self.openWindow = openWindow
        super.init()

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ReviewPanel(store: store, close: { [weak self] in self?.closePanel() }))
        popover.contentSize = PanelLayout.size
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clickStatusItem(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateLabel()
        storeSubscription = store.objectWillChange.sink { [weak self] _ in
            self?.scheduleLabelUpdate()
        }
    }

    private func scheduleLabelUpdate() {
        guard !labelUpdateScheduled else { return }
        labelUpdateScheduled = true
        // objectWillChange precedes the assignment. Read the final values next turn,
        // coalescing a refresh's snapshot, activity, error and timer notifications.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.labelUpdateScheduled = false
            self.updateLabel()
        }
    }

    private func updateLabel() {
        guard let button = statusItem.button else { return }
        let state = MenuBarImageState(store: store,
                                      scale: button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        if state != lastImageState {
            let renderer = ImageRenderer(content: MenuStatusLabel(state: state)
                .font(.system(size: 13)).foregroundStyle(.black).fixedSize())
            renderer.scale = state.scale
            if let image = renderer.nsImage {
                image.isTemplate = true
                button.image = image
                lastImageState = state
            }
        }
        let summary = store.menuBarSummary
        if summary != lastSummary {
            button.toolTip = summary
            button.setAccessibilityLabel(summary)
            lastSummary = summary
        }
        if menuLanguage != store.l10n.code {
            menuLanguage = store.l10n.code
            updateApplicationMenu()
        }
    }

    @objc private func clickStatusItem(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            closePanel()
            let menu = NSMenu()
            menu.addItem(menuItem("common.openWindow", action: #selector(showWindow)))
            menu.addItem(menuItem("settings.openMenu", action: #selector(showSettings)))
            menu.addItem(.separator())
            menu.addItem(menuItem("common.restart", action: #selector(restartApplication)))
            menu.addItem(quitMenuItem())
            // Let AppKit anchor the menu below the status item and manage tracking.
            // Detach it afterwards so primary clicks still toggle the PR panel.
            statusItem.menu = menu
            defer { statusItem.menu = nil }
            sender.performClick(nil)
        } else {
            togglePanel()
        }
    }

    func togglePanel() {
        if popover.isShown { closePanel() }
        else { showPanel() }
    }

    private func menuItem(_ key: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: store.l10n.text(key), action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func quitMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: store.l10n.text("common.quit"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.target = NSApp
        return item
    }

    private func updateApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu(title: "PRch")
        let settings = menuItem("settings.openMenu", action: #selector(showSettings))
        settings.keyEquivalent = ","
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("common.restart", action: #selector(restartApplication)))
        appMenu.addItem(quitMenuItem())
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Keep standard text-editing shortcuts available in hosted SwiftUI fields.
        let editMenu = NSMenu(title: store.l10n.text("menu.edit"))
        for (key, action, shortcut) in [
            ("menu.undo", "undo:", "z"), ("menu.redo", "redo:", "Z"),
            ("menu.cut", "cut:", "x"), ("menu.copy", "copy:", "c"),
            ("menu.paste", "paste:", "v"), ("menu.selectAll", "selectAll:", "a")
        ] {
            editMenu.addItem(NSMenuItem(title: store.l10n.text(key), action: Selector(action), keyEquivalent: shortcut))
        }
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            PanelKeyHandler.focusNavigation(in: window)
        }
        button.highlight(true)
    }

    func closePanel() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }

    @objc private func showWindow() {
        openWindow()
    }

    @objc private func restartApplication() {
        guard !isRestarting else { return }
        isRestarting = true
        closePanel()
        Task { @MainActor in
            defer { isRestarting = false }
            do {
                let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
                if Bundle.main.bundleURL.pathExtension == "app" {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    configuration.arguments = arguments
                    _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
                } else {
                    // Also support launching the executable directly during development.
                    let process = Process()
                    process.executableURL = Bundle.main.executableURL
                    process.arguments = arguments
                    try process.run()
                }
                // Keep the current instance available if launching its replacement fails.
                NSApp.terminate(nil)
            } catch {
                let alert = NSAlert()
                alert.messageText = store.l10n.text("restart.failedTitle")
                alert.informativeText = store.l10n.text("restart.failedMessage")
                alert.alertStyle = .warning
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func showSettings() {
        store.showSettings = true
        // Let menu tracking finish before opening the popover.
        DispatchQueue.main.async { [weak self] in self?.showPanel() }
    }
}

struct MenuBarImageState: Equatable {
    let hasError: Bool
    let style: MenuBarStyle
    let reviews: Int
    let outgoing: Int
    let unread: Int
    let activityStyle: ActivityIndicatorStyle
    let scale: CGFloat

    @MainActor init(store: AppStore, scale: CGFloat) {
        hasError = store.failure != nil
        style = store.menuBarStyle
        reviews = store.pendingCount
        outgoing = store.menuBarOutgoingCount
        unread = store.unreadActivityCount
        activityStyle = store.activityIndicatorStyle
        self.scale = scale
    }
}

private struct MenuStatusLabel: View {
    let state: MenuBarImageState

    var body: some View {
        HStack(spacing: 4) {
            if state.hasError {
                BrandMark()
                Image(systemName: "exclamationmark.circle")
            } else {
                MenuBarIndicator(style: state.style, reviews: state.reviews,
                                 outgoing: state.outgoing, unread: state.unread,
                                 activityStyle: state.activityStyle)
            }
        }
    }
}
