import AppKit
import SwiftUI

enum PanelKeyAction: Equatable {
    case next, previous, forward, back, open, search, cancel, focusList, incoming, outgoing, nextSection, previousSection

    static func resolve(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags,
                        mode: KeyboardMode, editing: Bool, composing: Bool = false) -> Self? {
        guard !composing else { return nil }
        let flags = modifiers.intersection(PanelShortcut.modifierMask)
        if flags.isEmpty && keyCode == 53 { return .cancel }
        if mode == .emacs && flags == .control && characters == "g" { return .cancel }
        if flags == .command {
            if characters == "1" { return .incoming }
            if characters == "2" { return .outgoing }
        }
        if editing {
            return flags.isEmpty && [36, 76].contains(keyCode) ? .focusList : nil
        }
        if keyCode == 48 {
            if flags.isEmpty { return .nextSection }
            if flags == .shift { return .previousSection }
        }
        if flags.isEmpty {
            switch keyCode {
            case 125: return .next
            case 126: return .previous
            case 124: return .forward
            case 123: return .back
            case 36, 76: return .open
            default: break
            }
        }
        if mode == .emacs && flags == .control {
            return ["n": .next, "p": .previous, "f": .forward, "b": .back, "s": .search][characters]
        }
        if mode == .vim && flags.isEmpty {
            return ["j": .next, "k": .previous, "l": .forward, "h": .back, "/": .search][characters]
        }
        return nil
    }
}

enum PanelListItem: Hashable {
    case repository(group: String, repository: String)
    case pullRequest(String)
    case pending

    static func moved(from selection: Self?, in items: [Self], forward: Bool) -> Self? {
        guard !items.isEmpty else { return nil }
        guard let selection, let index = items.firstIndex(of: selection) else { return forward ? items.first : items.last }
        return items[min(items.count - 1, max(0, index + (forward ? 1 : -1)))]
    }
}

enum PanelKeyboardSection: CaseIterable {
    case tabs, filters, list
}

/// Navigation includes the controls above the list, even when a filter has no PRs.
struct PanelNavigation {
    var section = PanelKeyboardSection.list
    var selection: PanelListItem?

    mutating func reconcile(items: [PanelListItem]) {
        if !hasSelection(in: items) { selection = nil }
        if items.isEmpty && section == .list { section = .filters }
    }

    mutating func focusList(items: [PanelListItem]) {
        section = items.isEmpty ? .filters : .list
        if !hasSelection(in: items) { selection = items.first }
    }

    mutating func cycleSection(forward: Bool, items: [PanelListItem]) {
        let sections: [PanelKeyboardSection] = items.isEmpty ? [.tabs, .filters] : [.tabs, .filters, .list]
        if let index = sections.firstIndex(of: section) {
            section = sections[(index + (forward ? 1 : sections.count - 1)) % sections.count]
        } else { section = forward ? .tabs : .filters }
        if section == .list { focusList(items: items) }
    }

    mutating func moveVertically(forward: Bool, items: [PanelListItem]) {
        switch section {
        case .tabs:
            if forward { section = .filters }
        case .filters:
            if forward { focusList(items: items) } else { section = .tabs }
        case .list:
            if items.isEmpty || (!forward && (selection == items.first || !hasSelection(in: items))) {
                section = .filters
            } else {
                selection = PanelListItem.moved(from: selection, in: items, forward: forward)
            }
        }
    }

    private func hasSelection(in items: [PanelListItem]) -> Bool {
        selection.map { items.contains($0) } ?? false
    }

    static func adjacent(_ current: String, in ids: [String], forward: Bool) -> String? {
        guard let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(ids.count - 1, max(0, index + (forward ? 1 : -1)))]
    }
}

struct PanelStatusFilter: Identifiable {
    let id: String
    let titleKey: String

    static func options(for tab: String) -> [Self] {
        if tab == "incoming" {
            return [.init(id: "pending", titleKey: "filter.pending"), .init(id: "done", titleKey: "filter.reviewed"),
                    .init(id: "all", titleKey: "common.all")]
        }
        return [.init(id: "all", titleKey: "common.all"), .init(id: "waiting", titleKey: "filter.waiting"),
                .init(id: "changes", titleKey: "filter.changes"), .init(id: "approved", titleKey: "filter.approved"),
                .init(id: "unrequested", titleKey: "filter.unrequested")]
    }
}

/// Monitor only the hosting key window; both a popover and a window can be mounted.
struct PanelKeyHandler: NSViewRepresentable {
    var handle: (NSEvent, NSWindow) -> Bool
    func makeNSView(context: Context) -> KeyView { KeyView(handle: handle) }
    func updateNSView(_ view: KeyView, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }

    final class KeyView: NSView {
        var handle: (NSEvent, NSWindow) -> Bool
        private var monitor: Any?
        init(handle: @escaping (NSEvent, NSWindow) -> Bool) {
            self.handle = handle
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow,
                      event.window === window, !self.isHiddenOrHasHiddenAncestor else { return event }
                return self.handle(event, window) ? nil : event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

struct KeyboardSettingsView: View {
    @ObservedObject var settings: KeyboardSettings
    @Environment(\.l10n) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l10n.text("keyboard.shortcut.title"))
                Spacer()
                ShortcutRecorder(settings: settings, l10n: l10n).frame(width: 200, height: 28)
                Button { settings.setShortcut(nil) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).disabled(settings.shortcut == nil && !settings.isRecording)
                    .help(l10n.text("keyboard.shortcut.clear"))
                    .accessibilityLabel(l10n.text("keyboard.shortcut.clear"))
            }
            Text(l10n.text(settings.isRecording ? "keyboard.shortcut.recordingHelp" : "keyboard.shortcut.help"))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = settings.errorKey {
                Text(l10n.text(error)).font(.system(size: 12)).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Picker(l10n.text("keyboard.mode.title"), selection: $settings.mode) {
                ForEach(KeyboardMode.allCases, id: \.self) { mode in Text(l10n.text(mode.titleKey)).tag(mode) }
            }
            Text(l10n.text(settings.mode.helpKey)).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n.text("keyboard.help.sections")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n.text("keyboard.help.common")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n.text("keyboard.hints.help")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var settings: KeyboardSettings
    let l10n: L10n
    func makeNSView(context: Context) -> RecorderButton { RecorderButton(settings: settings) }
    func updateNSView(_ button: RecorderButton, context: Context) {
        if !settings.isRecording { button.finish() }
        button.title = settings.isRecording ? l10n.text("keyboard.shortcut.recording") :
            settings.shortcut?.display ?? l10n.text("keyboard.shortcut.record")
        button.setAccessibilityLabel(l10n.text("keyboard.shortcut.title"))
        button.setAccessibilityValue(button.title)
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.finish() }

    final class RecorderButton: NSButton {
        let settings: KeyboardSettings
        private var monitor: Any?
        init(settings: KeyboardSettings) {
            self.settings = settings
            super.init(frame: .zero)
            bezelStyle = .rounded
            target = self
            action = #selector(begin)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }

        @objc private func begin() {
            if settings.isRecording { finish(); return }
            guard window?.makeFirstResponder(self) == true else { return }
            settings.beginRecording()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.settings.isRecording, let window = self.window,
                      window.isKeyWindow, event.window === window else { return event }
                if event.isARepeat { return nil }
                let flags = event.modifierFlags.intersection(PanelShortcut.modifierMask)
                if flags.isEmpty && event.keyCode == 53 { self.finish() }
                else if flags.isEmpty && [51, 117].contains(event.keyCode) {
                    self.settings.setShortcut(nil)
                    self.finish()
                } else if self.settings.setShortcut(PanelShortcut(event: event)) { self.finish() }
                return nil
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(finish), name: NSWindow.didResignKeyNotification, object: window)
                NotificationCenter.default.addObserver(self, selector: #selector(finish), name: NSWindow.willCloseNotification, object: window)
            } else { finish() }
        }

        override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
        @objc func finish() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            settings.cancelRecording()
        }
    }
}
