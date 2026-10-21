import AppKit
import Testing
@testable import PRch

private func key(_ text: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [],
                 mode: KeyboardMode = .emacs, editing: Bool = false, composing: Bool = false) -> PanelKeyAction? {
    PanelKeyAction.resolve(keyCode: code, characters: text, modifiers: flags,
                           mode: mode, editing: editing, composing: composing)
}

@Test func navigationModesRespectModifiersTextEditingAndIME() {
    for (letter, expected) in [("n", PanelKeyAction.next), ("p", .previous), ("f", .forward), ("b", .back), ("s", .search)] {
        #expect(key(letter, flags: .control) == expected)
        #expect(key(letter) == nil)
        #expect(key(letter, flags: [.control, .shift]) == nil)
        #expect(key(letter, flags: .control, mode: .vim) == nil)
        #expect(key(letter, flags: .control, editing: true) == nil)
        #expect(key(letter, flags: .control, composing: true) == nil)
    }
    for (letter, expected) in [("j", PanelKeyAction.next), ("k", .previous), ("l", .forward), ("h", .back), ("/", .search)] {
        #expect(key(letter, mode: .vim) == expected)
        #expect(key(letter, mode: .standard) == nil)
        #expect(key(letter, flags: .command, mode: .vim) == nil)
        #expect(key(letter, mode: .vim, editing: true) == nil)
        #expect(key(letter, mode: .vim, composing: true) == nil)
    }
    for mode in KeyboardMode.allCases {
        #expect(key("\t", code: 48, mode: mode) == .nextSection)
        #expect(key("\t", code: 48, flags: .shift, mode: mode) == .previousSection)
        #expect(key("\t", code: 48, flags: .control, mode: mode) == nil)
        #expect(key("\t", code: 48, mode: mode, editing: true) == nil)
        #expect(key("\t", code: 48, flags: .shift, mode: mode, editing: true) == nil)
        #expect(key("\t", code: 48, mode: mode, composing: true) == nil)
        #expect(key("", code: 125, flags: .function, mode: mode) == .next)
        #expect(key("", code: 126, mode: mode) == .previous)
        #expect(key("", code: 124, mode: mode) == .forward)
        #expect(key("", code: 123, mode: mode) == .back)
        #expect(key("", code: 36, mode: mode) == .open)
        #expect(key("", code: 36, mode: mode, editing: true) == .focusList)
        #expect(key("", code: 36, mode: mode, editing: true, composing: true) == nil)
        #expect(key("", code: 53, mode: mode, composing: true) == nil)
        #expect(key("", code: 53, mode: mode, editing: true) == .cancel)
        #expect(key("1", flags: .command, mode: mode) == .incoming)
        #expect(key("2", flags: .command, mode: mode) == .outgoing)
    }
    #expect(key("g", flags: .control, editing: true) == .cancel)
    #expect(key("g", flags: .control, mode: .vim, editing: true) == nil)
}

@Test func headerControlsRemainReachableWithZeroMatchingPRs() {
    var navigation = PanelNavigation()
    navigation.reconcile(items: [])
    #expect(navigation.section == .filters)
    let incoming = PanelStatusFilter.options(for: "incoming").map(\.id)
    #expect(incoming == ["pending", "done", "all"])
    #expect(PanelNavigation.adjacent("pending", in: incoming, forward: true) == "done")
    #expect(PanelNavigation.adjacent("all", in: incoming, forward: true) == "all")
    #expect(PanelNavigation.adjacent("pending", in: incoming, forward: false) == "pending")
    navigation.moveVertically(forward: false, items: [])
    #expect(navigation.section == .tabs)
    #expect(PanelNavigation.adjacent("incoming", in: ["incoming", "outgoing"], forward: true) == "outgoing")
    let outgoing = PanelStatusFilter.options(for: "outgoing").map(\.id)
    #expect(outgoing == ["all", "waiting", "changes", "approved", "unrequested"])
    #expect(PanelNavigation.adjacent("changes", in: outgoing, forward: false) == "waiting")
    navigation.moveVertically(forward: true, items: [])
    #expect(navigation.section == .filters)
    navigation.focusList(items: [])
    #expect(navigation.section == .filters)
    navigation.cycleSection(forward: true, items: [])
    #expect(navigation.section == .tabs)
    navigation.cycleSection(forward: false, items: [])
    #expect(navigation.section == .filters)
}

@Test func navigationMovesBetweenHeaderRowsAndListWithoutLosingSelection() {
    let first = PanelListItem.repository(group: "incoming:regular:example-org/sample-web", repository: "example-org/sample-web")
    let row = PanelListItem.pullRequest("first")
    let items = [first, row]
    var navigation = PanelNavigation()
    navigation.moveVertically(forward: true, items: items)
    #expect(navigation.section == .list && navigation.selection == first)
    navigation.moveVertically(forward: false, items: items)
    #expect(navigation.section == .filters)
    navigation.moveVertically(forward: false, items: items)
    #expect(navigation.section == .tabs)
    navigation.moveVertically(forward: true, items: items)
    navigation.moveVertically(forward: true, items: items)
    navigation.moveVertically(forward: true, items: items)
    #expect(navigation.section == .list && navigation.selection == row)
    for expected in [PanelKeyboardSection.tabs, .filters, .list] {
        navigation.cycleSection(forward: true, items: items)
        #expect(navigation.section == expected)
        #expect(navigation.selection == row)
    }
    for expected in [PanelKeyboardSection.filters, .tabs, .list] {
        navigation.cycleSection(forward: false, items: items)
        #expect(navigation.section == expected)
    }
    navigation.reconcile(items: [])
    #expect(navigation.section == .filters && navigation.selection == nil)
    navigation.focusList(items: [first])
    #expect(navigation.section == .list && navigation.selection == first)
}

@Test func navigationUsesVisibleItemsAndClampsAtBoundaries() {
    let header = PanelListItem.repository(group: "incoming:regular:example-org/sample-web", repository: "example-org/sample-web")
    let first = PanelListItem.pullRequest("first"), second = PanelListItem.pullRequest("second")
    let visible = [header, first, second, .pending]
    #expect(PanelListItem.moved(from: nil, in: visible, forward: true) == header)
    #expect(PanelListItem.moved(from: nil, in: visible, forward: false) == .pending)
    #expect(PanelListItem.moved(from: header, in: visible, forward: false) == header)
    #expect(PanelListItem.moved(from: first, in: visible, forward: true) == second)
    #expect(PanelListItem.moved(from: .pending, in: visible, forward: true) == .pending)
    #expect(PanelListItem.moved(from: first, in: [header], forward: true) == header)
    #expect(PanelListItem.moved(from: first, in: [], forward: true) == nil)
}

@MainActor
private final class FakeHotKey: PanelHotKeyRegistering {
    var registered: PanelShortcut?
    var action: (@MainActor () -> Void)?
    var rejected: PanelShortcut?
    func register(_ shortcut: PanelShortcut, action: @escaping @MainActor () -> Void) -> Bool {
        guard shortcut != rejected else { return false }
        registered = shortcut
        self.action = action
        return true
    }
    func unregister() { registered = nil; action = nil }
}

@Test @MainActor func shortcutRecordingPersistsOnlySuccessfulChangesAndRestoresOnCancel() throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let registrar = FakeHotKey()
    let settings = KeyboardSettings(defaults: defaults, hotKey: registrar)
    var activations = 0
    settings.start { activations += 1 }
    #expect(settings.mode == .emacs)
    #expect(settings.shortcut == nil)
    let original = PanelShortcut(keyCode: 35, modifiers: [.control, .option], keyLabel: "P")
    #expect(settings.setShortcut(original))
    registrar.action?()
    #expect(activations == 1)
    settings.mode = .vim
    let saved = defaults.data(forKey: "panelShortcut")
    settings.beginRecording()
    #expect(settings.isRecording && registrar.registered == nil)
    let bare = PanelShortcut(keyCode: 38, modifiers: [], keyLabel: "J")
    #expect(!settings.setShortcut(bare))
    #expect(settings.isRecording)
    let conflict = PanelShortcut(keyCode: 40, modifiers: .command, keyLabel: "K")
    registrar.rejected = conflict
    #expect(!settings.setShortcut(conflict))
    #expect(settings.errorKey == "keyboard.shortcut.unavailable")
    #expect(settings.shortcut == original)
    #expect(defaults.data(forKey: "panelShortcut") == saved)
    settings.cancelRecording()
    #expect(!settings.isRecording && settings.errorKey == nil)
    #expect(registrar.registered == original)
    let restarted = KeyboardSettings(defaults: defaults, hotKey: FakeHotKey())
    #expect(restarted.mode == .vim && restarted.shortcut == original)
    settings.beginRecording()
    #expect(settings.setShortcut(nil))
    #expect(!settings.isRecording && registrar.registered == nil)
    #expect(KeyboardSettings(defaults: defaults, hotKey: FakeHotKey()).shortcut == nil)
    settings.stop()
}

@Test @MainActor func shortcutStartupConflictAndMalformedPreferencesAreRecoverable() throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let shortcut = PanelShortcut(keyCode: 35, modifiers: [.command, .shift], keyLabel: "P")
    defaults.set(try JSONEncoder().encode(shortcut), forKey: "panelShortcut")
    let registrar = FakeHotKey()
    registrar.rejected = shortcut
    let settings = KeyboardSettings(defaults: defaults, hotKey: registrar)
    settings.start {}
    #expect(settings.shortcut == shortcut && settings.errorKey != nil)
    settings.beginRecording()
    let replacement = PanelShortcut(keyCode: 35, modifiers: [.command, .control], keyLabel: "P")
    #expect(settings.setShortcut(replacement))
    #expect(registrar.registered == replacement && settings.errorKey == nil)
    settings.stop()
    #expect(registrar.registered == nil)
    defaults.set(Data("broken".utf8), forKey: "panelShortcut")
    defaults.set("unknown", forKey: "keyboardMode")
    let malformed = KeyboardSettings(defaults: defaults, hotKey: FakeHotKey())
    #expect(malformed.shortcut == nil && malformed.mode == .emacs)
    defaults.set(try JSONEncoder().encode(PanelShortcut(keyCode: 35, modifiers: .shift, keyLabel: "P")), forKey: "panelShortcut")
    #expect(KeyboardSettings(defaults: defaults, hotKey: FakeHotKey()).shortcut == nil)
}

@Test func shortcutNormalizesModifierFlagsAndFormatsSpecialKeys() throws {
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.control, .option, .capsLock, .numericPad], timestamp: 0, windowNumber: 0,
        context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    let shortcut = PanelShortcut(event: event)
    #expect(shortcut.isValid && shortcut.flags == [.control, .option])
    #expect(shortcut.display == "⌃⌥Space")
    #expect(try JSONDecoder().decode(PanelShortcut.self, from: JSONEncoder().encode(shortcut)) == shortcut)
    #expect(!PanelShortcut(keyCode: 55, modifiers: .command, keyLabel: "⌘").isValid)
    #expect(!PanelShortcut(keyCode: 999, modifiers: .command, keyLabel: "Unknown").isValid)
}
