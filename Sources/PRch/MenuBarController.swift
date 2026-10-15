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
    private var menuLanguage: String?

    init(store: AppStore, openWindow: @escaping () -> Void) {
        self.store = store
        self.openWindow = openWindow
        super.init()

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ReviewPanel(store: store))
        popover.contentSize = NSSize(width: 440, height: 624)
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clickStatusItem(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateLabel()
        // objectWillChange fires before the new values are stored.
        storeSubscription = store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateLabel()
        }
    }

    private func updateLabel() {
        guard let button = statusItem.button else { return }
        let renderer = ImageRenderer(content: MenuStatusLabel(store: store)
            .font(.system(size: 13)).foregroundStyle(.black).fixedSize())
        renderer.scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = true
        button.image = image
        button.toolTip = store.menuBarSummary
        button.setAccessibilityLabel(store.menuBarSummary)
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
            menu.addItem(quitMenuItem())
            sender.highlight(true)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
            sender.highlight(false)
        } else if popover.isShown {
            closePanel()
        } else {
            showPanel()
        }
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
        popover.contentViewController?.view.window?.makeKey()
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

    @objc private func showSettings() {
        store.showSettings = true
        // Let menu tracking finish before opening the popover.
        DispatchQueue.main.async { [weak self] in self?.showPanel() }
    }
}

private struct MenuStatusLabel: View {
    let store: AppStore

    var body: some View {
        HStack(spacing: 4) {
            if store.error != nil {
                BrandMark()
                Image(systemName: "exclamationmark.circle")
            } else {
                MenuBarIndicator(style: store.menuBarStyle, reviews: store.pendingCount,
                                 changes: store.changesRequestedCount, unread: store.unreadActivityCount,
                                 activityStyle: store.activityIndicatorStyle)
            }
        }
    }
}
