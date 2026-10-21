import AppKit
import SwiftUI

enum KeyboardHintTarget: Hashable {
    case tab(String), filter(String), item(PanelListItem)
    case search, activity, refresh, settings
    case back, open, star, pending
}

struct KeyboardHintPresentation {
    var labels: [KeyboardHintTarget: String] = [:]
    var prefix = ""
}

/// Freeze labels for a hint session so a partial key cannot jump to a different PR.
struct KeyboardHintSession {
    enum Result: Equatable {
        case pending, selected(KeyboardHintTarget), cancel, passThrough
    }
    private(set) var presentation = KeyboardHintPresentation()
    private let mode: KeyboardMode
    private let alphabet: [Character]

    init(targets: [KeyboardHintTarget], mode: KeyboardMode) {
        self.mode = mode
        // Vim's unmodified navigation keys must remain available even with hints visible.
        alphabet = Array(mode == .vim ? "ASDFGQWERTYUIOPZXCVBNM" : "ASDFGHJKLQWERTYUIOPZXCVBNM")
        var unique: [KeyboardHintTarget] = []
        var seen: Set<KeyboardHintTarget> = []
        for target in targets where seen.insert(target).inserted { unique.append(target) }
        var width = 1, capacity = alphabet.count
        while capacity < unique.count { width += 1; capacity *= alphabet.count }
        for (index, target) in unique.enumerated() {
            var value = index
            var characters = Array(repeating: alphabet[0], count: width)
            for position in (0..<width).reversed() {
                characters[position] = alphabet[value % alphabet.count]
                value /= alphabet.count
            }
            presentation.labels[target] = String(characters)
        }
    }

    static func isToggle(characters: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        characters == "?" && modifiers.intersection(PanelShortcut.modifierMask).subtracting(.shift).isEmpty
    }

    mutating func handle(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags,
                         isRepeat: Bool = false) -> Result {
        let flags = modifiers.intersection(PanelShortcut.modifierMask)
        if isRepeat, Self.isToggle(characters: characters, modifiers: modifiers) { return .pending }
        if (flags.isEmpty && keyCode == 53) || Self.isToggle(characters: characters, modifiers: modifiers) ||
            (mode == .emacs && flags == .control && characters == "g") { return .cancel }
        if flags.isEmpty && [51, 117].contains(keyCode) {
            if !presentation.prefix.isEmpty { presentation.prefix.removeLast() }
            return .pending
        }
        // Existing navigation and Command shortcuts leave hints and continue normally.
        let normalized = characters.uppercased()
        guard flags.subtracting(.shift).isEmpty,
              normalized.count == 1, let character = normalized.first,
              alphabet.contains(character) else { return .passThrough }
        guard !isRepeat else { return .pending }
        let prefix = presentation.prefix + String(character)
        if let target = presentation.labels.first(where: { $0.value == prefix })?.key { return .selected(target) }
        if presentation.labels.values.contains(where: { $0.hasPrefix(prefix) }) { presentation.prefix = prefix }
        else { presentation.prefix = "" }
        return .pending
    }
}

private struct KeyboardHintEnvironmentKey: EnvironmentKey {
    static let defaultValue = KeyboardHintPresentation()
}

extension EnvironmentValues {
    var keyboardHints: KeyboardHintPresentation {
        get { self[KeyboardHintEnvironmentKey.self] }
        set { self[KeyboardHintEnvironmentKey.self] = newValue }
    }
}

private struct KeyboardHintModifier: ViewModifier {
    @Environment(\.keyboardHints) private var hints
    let target: KeyboardHintTarget

    func body(content: Content) -> some View {
        HStack(spacing: 3) {
            if let label = hints.labels[target] {
                let matches = label.hasPrefix(hints.prefix)
                (Text(matches ? hints.prefix : "").foregroundColor(Palette.amber.opacity(0.45))
                 + Text(matches ? String(label.dropFirst(hints.prefix.count)) : label).foregroundColor(Palette.amber))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 3).padding(.vertical, 2)
                    .background(Palette.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                    .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.amber.opacity(0.45)) }
                    .fixedSize().opacity(matches ? 1 : 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            content
        }
    }
}

extension View {
    func keyboardHint(_ target: KeyboardHintTarget) -> some View { modifier(KeyboardHintModifier(target: target)) }
}
