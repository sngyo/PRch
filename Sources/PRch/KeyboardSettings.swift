import AppKit
import Carbon
import Combine

enum KeyboardMode: String, CaseIterable {
    case standard, emacs, vim
    var titleKey: String { "keyboard.mode.\(rawValue)" }
    var helpKey: String { "keyboard.help.\(rawValue)" }
}

struct PanelShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt
    let keyLabel: String

    static let modifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var isValid: Bool {
        keyCode < 128 && !keyLabel.isEmpty && keyLabel.count <= 20 &&
        modifiers == flags.intersection(Self.modifierMask).rawValue &&
        !flags.intersection([.command, .control]).isEmpty &&
        ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(Int(keyCode))
    }
    var display: String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }.map(\.1).joined() + keyLabel
    }
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        for (flag, value) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey),
                              (.shift, shiftKey), (.command, cmdKey)] where flags.contains(flag) {
            result |= UInt32(value)
        }
        return result
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.modifierMask).rawValue
        self.keyLabel = keyLabel
    }

    init(event: NSEvent) {
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤",
            117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags,
                  keyLabel: special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "")
    }
}

@MainActor
protocol PanelHotKeyRegistering: AnyObject {
    func register(_ shortcut: PanelShortcut, action: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

/// Carbon registers only the chosen combination, without monitoring global typing.
@MainActor
final class PanelHotKey: PanelHotKeyRegistering {
    // Mutations happen on the main actor; deinit only releases the C resources.
    nonisolated(unsafe) private var hotKey: EventHotKeyRef?
    nonisolated(unsafe) private var handler: EventHandlerRef?
    private var registered: PanelShortcut?
    private var action: (@MainActor () -> Void)?
    private let signature: OSType = 0x50526368 // PRch
    private static var nextIdentifier: UInt32 = 0
    private var identifier: UInt32 = 0
    private var keyIsDown = false

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ shortcut: PanelShortcut, action: @escaping @MainActor () -> Void) -> Bool {
        guard shortcut.isValid else { return false }
        if registered == shortcut { self.action = action; return true }
        // System symbolic shortcuts are not always reported as registration conflicts.
        var symbolic: Unmanaged<CFArray>?
        if CopySymbolicHotKeys(&symbolic) == noErr,
           let entries = symbolic?.takeRetainedValue() as? [[String: Any]],
           entries.contains(where: {
               ($0[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true &&
               ($0[kHISymbolicHotKeyCode] as? NSNumber)?.uint16Value == shortcut.keyCode &&
               ($0[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value == shortcut.carbonModifiers
           }) { return false }
        if handler == nil {
            var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<PanelHotKey>.fromOpaque(context).takeUnretainedValue()
                    var id = EventHotKeyID()
                    guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                            nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                          id.signature == owner.signature, id.id == owner.identifier else { return OSStatus(eventNotHandledErr) }
                    if GetEventKind(event) == UInt32(kEventHotKeyReleased) { owner.keyIsDown = false }
                    else if !owner.keyIsDown { owner.keyIsDown = true; owner.action?() }
                    return noErr
                }
            }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return false }
        }
        var candidate: EventHotKeyRef?
        Self.nextIdentifier &+= 1
        let nextID = Self.nextIdentifier
        guard RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                  EventHotKeyID(signature: signature, id: nextID), GetApplicationEventTarget(),
                                  OptionBits(kEventHotKeyExclusive), &candidate) == noErr else { return false }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate
        identifier = nextID
        keyIsDown = false
        registered = shortcut
        self.action = action
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registered = nil
        action = nil
        keyIsDown = false
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

@MainActor
final class KeyboardSettings: ObservableObject {
    @Published var mode: KeyboardMode { didSet { defaults.set(mode.rawValue, forKey: "keyboardMode") } }
    @Published private(set) var shortcut: PanelShortcut?
    @Published private(set) var isRecording = false
    @Published private(set) var errorKey: String?
    private let defaults: UserDefaults
    private let hotKey: any PanelHotKeyRegistering
    private var action: (@MainActor () -> Void)?

    init(defaults: UserDefaults, hotKey: (any PanelHotKeyRegistering)? = nil) {
        self.defaults = defaults
        self.hotKey = hotKey ?? PanelHotKey()
        mode = defaults.string(forKey: "keyboardMode").flatMap(KeyboardMode.init(rawValue:)) ?? .emacs
        if let data = defaults.data(forKey: "panelShortcut"),
           let saved = try? JSONDecoder().decode(PanelShortcut.self, from: data), saved.isValid { shortcut = saved }
    }

    func start(action: @escaping @MainActor () -> Void) {
        self.action = action
        restoreRegistration()
    }

    func stop() {
        hotKey.unregister()
        action = nil
        isRecording = false
    }

    func beginRecording() {
        hotKey.unregister()
        errorKey = nil
        isRecording = true
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        restoreRegistration()
    }

    @discardableResult
    func setShortcut(_ candidate: PanelShortcut?) -> Bool {
        if let candidate {
            guard candidate.isValid else { errorKey = "keyboard.shortcut.invalid"; return false }
            if let action, !hotKey.register(candidate, action: action) {
                errorKey = "keyboard.shortcut.unavailable"
                return false
            }
        } else { hotKey.unregister() }
        shortcut = candidate
        if let candidate, let data = try? JSONEncoder().encode(candidate) { defaults.set(data, forKey: "panelShortcut") }
        else { defaults.removeObject(forKey: "panelShortcut") }
        errorKey = nil
        isRecording = false
        return true
    }

    private func restoreRegistration() {
        errorKey = nil
        if let shortcut, let action, !hotKey.register(shortcut, action: action) {
            errorKey = "keyboard.shortcut.unavailable"
        }
    }
}
