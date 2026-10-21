import AppKit
import Testing
@testable import PRch

@Test func hintLabelsAreUniquePrefixFreeAndEveryTargetIsReachable() {
    for mode in KeyboardMode.allCases {
        for count in [0, 1, 22, 26, 27, 500, 700] {
            let targets = (0..<count).map { KeyboardHintTarget.item(.pullRequest("pr-\($0)")) }
            let session = KeyboardHintSession(targets: targets + targets.prefix(2), mode: mode)
            let labels = session.presentation.labels
            #expect(labels.count == count)
            #expect(Set(labels.values).count == count)
            #expect(Set(labels.values.map(\.count)).count <= 1)
            #expect(KeyboardHintSession(targets: targets, mode: mode).presentation.labels == labels)
            for (target, label) in labels {
                if mode == .vim { #expect(label.allSatisfy { !"HJKL".contains($0) }) }
                var input = session
                for (index, letter) in label.enumerated() {
                    let result = input.handle(keyCode: 0, characters: String(letter).lowercased(), modifiers: [])
                    #expect(result == (index == label.count - 1 ? .selected(target) : .pending))
                }
            }
        }
    }
}

@Test func hintsPreserveVimNavigationAndCommandShortcuts() {
    var session = KeyboardHintSession(targets: [.tab("incoming"), .tab("outgoing")], mode: .vim)
    for key in ["h", "j", "k", "l", "/", "\t", "\r", "あ", "ß"] {
        #expect(session.handle(keyCode: 0, characters: key, modifiers: []) == .passThrough)
    }
    for (key, flags) in [("1", NSEvent.ModifierFlags.command), ("f", .command), ("n", .control), ("a", .option)] {
        #expect(session.handle(keyCode: 0, characters: key, modifiers: flags) == .passThrough)
    }
    #expect(session.handle(keyCode: 0, characters: "A", modifiers: [.shift, .capsLock]) == .selected(.tab("incoming")))
    #expect(session.handle(keyCode: 0, characters: "s", modifiers: []) == .selected(.tab("outgoing")))
}

@Test func partialHintsSupportCorrectionCancellationAndIgnoreHeldKeys() {
    let targets = (0..<30).map { KeyboardHintTarget.item(.pullRequest("pr-\($0)")) }
    var session = KeyboardHintSession(targets: targets, mode: .emacs)
    #expect(session.handle(keyCode: 0, characters: "a", modifiers: []) == .pending)
    #expect(session.presentation.prefix == "A")
    #expect(session.handle(keyCode: 0, characters: "a", modifiers: [], isRepeat: true) == .pending)
    #expect(session.presentation.prefix == "A")
    #expect(session.handle(keyCode: 51, characters: "", modifiers: []) == .pending)
    #expect(session.presentation.prefix.isEmpty)
    #expect(session.handle(keyCode: 0, characters: "z", modifiers: []) == .pending)
    #expect(session.presentation.prefix.isEmpty)
    #expect(session.handle(keyCode: 0, characters: "a", modifiers: []) == .pending)
    #expect(session.handle(keyCode: 0, characters: "s", modifiers: []) == .selected(targets[1]))
    #expect(session.handle(keyCode: 53, characters: "", modifiers: []) == .cancel)
    #expect(session.handle(keyCode: 0, characters: "g", modifiers: .control) == .cancel)
    #expect(session.handle(keyCode: 0, characters: "?", modifiers: .shift) == .cancel)
    #expect(session.handle(keyCode: 0, characters: "?", modifiers: .shift, isRepeat: true) == .pending)
}

@Test func hintToggleDoesNotCaptureModifiedCommands() {
    #expect(KeyboardHintSession.isToggle(characters: "?", modifiers: []))
    #expect(KeyboardHintSession.isToggle(characters: "?", modifiers: [.shift, .capsLock]))
    #expect(!KeyboardHintSession.isToggle(characters: "/", modifiers: []))
    for flags: NSEvent.ModifierFlags in [.command, .control, .option, [.command, .shift]] {
        #expect(!KeyboardHintSession.isToggle(characters: "?", modifiers: flags))
    }
}
