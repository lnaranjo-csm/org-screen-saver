import Foundation

/// A platform-neutral description of one input event, built by the event tap.
public struct KeyInput: Equatable {
    public enum Kind: Equatable { case keyDown, keyUp, flagsChanged, systemDefined, pointer, other }

    public var kind: Kind
    public var keyCode: Int
    public var command: Bool
    public var control: Bool
    public var option: Bool
    /// For `.systemDefined` events (media / brightness keys).
    public var sysSubtype: Int
    public var sysKeyCode: Int
    public var sysKeyDown: Bool

    public init(kind: Kind, keyCode: Int = 0, command: Bool = false, control: Bool = false,
                option: Bool = false, sysSubtype: Int = 0, sysKeyCode: Int = 0, sysKeyDown: Bool = false) {
        self.kind = kind
        self.keyCode = keyCode
        self.command = command
        self.control = control
        self.option = option
        self.sysSubtype = sysSubtype
        self.sysKeyCode = sysKeyCode
        self.sysKeyDown = sysKeyDown
    }
}

public enum KeyAction: Equatable {
    case pass
    case drop
    case digit(Int)
    case backspace
    case escapeUnlock
}

public struct KeyDecision: Equatable {
    public var action: KeyAction
    /// True when this event is a "foreign" key press that should trigger a webcam snapshot.
    public var snapshot: Bool
}

/// Decides what to do with every input event while the screen saver is active.
public enum KeyClassifier {
    /// Main-row digit key codes -> digit value.
    static let mainRowDigits: [Int: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    /// Keypad digit key codes -> digit value.
    static let keypadDigits: [Int: Int] = [82: 0, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9]
    /// F1 / F2 (122 / 120), plus the legacy brightness key codes (145 / 144).
    static let brightnessKeyCodes: Set<Int> = [122, 120, 145, 144]
    /// NX_KEYTYPE_BRIGHTNESS_UP = 2, NX_KEYTYPE_BRIGHTNESS_DOWN = 3.
    static let brightnessSystemKeys: Set<Int> = [2, 3]
    static let escapeKeyCode = 53
    static let backspaceKeyCode = 51

    public static func digit(forKeyCode code: Int) -> Int? {
        mainRowDigits[code] ?? keypadDigits[code]
    }

    public static func classify(_ input: KeyInput, locked: Bool, testMode: Bool) -> KeyDecision {
        guard locked else { return KeyDecision(action: .pass, snapshot: false) }

        switch input.kind {
        case .pointer, .other, .flagsChanged:
            return KeyDecision(action: .drop, snapshot: false)

        case .systemDefined:
            if input.sysSubtype == 8 && brightnessSystemKeys.contains(input.sysKeyCode) {
                return KeyDecision(action: .pass, snapshot: false)
            }
            // Other media / power-style keys: dropped; a key-down counts as a foreign key press.
            return KeyDecision(action: .drop, snapshot: input.sysSubtype == 8 && input.sysKeyDown)

        case .keyUp:
            if brightnessKeyCodes.contains(input.keyCode) {
                return KeyDecision(action: .pass, snapshot: false)
            }
            return KeyDecision(action: .drop, snapshot: false)

        case .keyDown:
            if brightnessKeyCodes.contains(input.keyCode) {
                return KeyDecision(action: .pass, snapshot: false)
            }
            let hasModifier = input.command || input.control || input.option
            if !hasModifier, let d = digit(forKeyCode: input.keyCode) {
                return KeyDecision(action: .digit(d), snapshot: false)
            }
            if testMode && input.keyCode == escapeKeyCode {
                return KeyDecision(action: .escapeUnlock, snapshot: false)
            }
            if input.keyCode == backspaceKeyCode && !hasModifier {
                return KeyDecision(action: .backspace, snapshot: true)
            }
            return KeyDecision(action: .drop, snapshot: true)
        }
    }
}
