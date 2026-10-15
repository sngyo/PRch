import AppKit
import SwiftUI

/// Popovers and regular windows can remain mounted when ordered off screen.
/// Observe the hosting window as well as SwiftUI's disappearance lifecycle.
struct PanelActivityObserver: NSViewRepresentable {
    var changed: (Bool, Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView(changed: changed) }
    func updateNSView(_ view: ObserverView, context: Context) { view.changed = changed }

    final class ObserverView: NSView {
        var changed: (Bool, Bool) -> Void
        private var previousActive: Bool?
        private var previousClosed: Bool?

        init(changed: @escaping (Bool, Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowClosed), name: NSApplication.willTerminateNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(popoverClosed), name: NSPopover.willCloseNotification, object: nil)
            scheduleReport()
        }

        @objc private func popoverClosed(_ notification: Notification) {
            guard let popover = notification.object as? NSPopover,
                  let window, popover.contentViewController?.view.window === window else { return }
            windowClosed(notification)
        }

        @objc private func windowChanged(_ notification: Notification) { scheduleReport() }
        @objc private func windowClosed(_ notification: Notification) {
            previousActive = false
            previousClosed = true
            changed(false, true)
        }
        private func scheduleReport() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let closed = !window.isVisible || window.isMiniaturized
                let active = !closed && window.isKeyWindow && window.occlusionState.contains(.visible)
                guard active != self.previousActive || closed != self.previousClosed else { return }
                self.previousActive = active
                self.previousClosed = closed
                self.changed(active, closed)
            }
        }
    }
}

struct ActivityRowFrames: PreferenceKey {
    static let defaultValue: [ActivityReceipt: CGRect] = [:]
    static func reduce(value: inout [ActivityReceipt: CGRect], nextValue: () -> [ActivityReceipt: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
