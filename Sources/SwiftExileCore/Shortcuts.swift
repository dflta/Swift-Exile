import Foundation

/// A hotkey in upstream's grammar, e.g. `"Ctrl + Shift + D"` (`ipc/KeyToCode.ts`).
public struct Hotkey: Equatable, Hashable, Sendable {
    public var key: String
    public var ctrl: Bool
    public var shift: Bool
    public var alt: Bool

    public init(key: String, ctrl: Bool = false, shift: Bool = false, alt: Bool = false) {
        self.key = key
        self.ctrl = ctrl
        self.shift = shift
        self.alt = alt
    }

    /// Nil for modifier-only strings like `"Alt"`, which can't be registered as shortcuts.
    public init?(_ string: String) {
        let parts = string.components(separatedBy: " + ")
        let plain = parts.filter { !KeyNames.isModifier($0) }
        guard plain.count == 1, let key = plain.first, !key.isEmpty else { return nil }
        self.init(key: key, ctrl: parts.contains("Ctrl"), shift: parts.contains("Shift"), alt: parts.contains("Alt"))
    }

    public var string: String { KeyNames.hotkeyString(keys: [key], ctrl: ctrl, shift: shift, alt: alt) }

    public var macKeyCode: UInt16? { KeyNames.macKeyCode(for: key) }
}

/// `ShortcutAction` from `ipc/types.ts:18-50`.
public struct ShortcutAction: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case copyItem(target: String, focusOverlay: Bool)
        case ocrText(target: String)
        case triggerEvent(target: String)
        case stashSearch(text: String)
        case toggleOverlay
        case pasteInChat(text: String, send: Bool)
        case testOnly
        case unknown(type: String)

        var isTestOnly: Bool { self == .testOnly }
        var isToggleOverlay: Bool { self == .toggleOverlay }
    }

    public var shortcut: String
    public var keepModKeys: Bool
    public var action: Action

    public init(shortcut: String, keepModKeys: Bool = false, action: Action) {
        self.shortcut = shortcut
        self.keepModKeys = keepModKeys
        self.action = action
    }

    /// Decodes one entry of `HostConfig.shortcuts`.
    public init?(json: JSONValue) {
        guard case .object(let object) = json,
              case .string(let shortcut)? = object["shortcut"],
              case .object(let action)? = object["action"],
              case .string(let type)? = action["type"]
        else { return nil }
        func string(_ key: String) -> String? {
            if case .string(let value)? = action[key] { return value }
            return nil
        }
        func bool(_ key: String) -> Bool {
            if case .bool(let value)? = action[key] { return value }
            return false
        }
        let parsed: Action
        switch type {
        case "copy-item": parsed = .copyItem(target: string("target") ?? "", focusOverlay: bool("focusOverlay"))
        case "ocr-text": parsed = .ocrText(target: string("target") ?? "")
        case "trigger-event": parsed = .triggerEvent(target: string("target") ?? "")
        case "stash-search": parsed = .stashSearch(text: string("text") ?? "")
        case "toggle-overlay": parsed = .toggleOverlay
        case "paste-in-chat": parsed = .pasteInChat(text: string("text") ?? "", send: bool("send"))
        case "test-only": parsed = .testOnly
        default: parsed = .unknown(type: type)
        }
        var keepModKeys = false
        if case .bool(let value)? = object["keepModKeys"] { keepModKeys = value }
        self.init(shortcut: shortcut, keepModKeys: keepModKeys, action: parsed)
    }
}

/// Port of `Shortcuts.updateActions` (`main/src/shortcuts/Shortcuts.ts:110-176`): drops hotkeys
/// reserved by the game and duplicates (except `toggle-overlay`), and adds the copy-item chord.
public enum ShortcutRegistry {
    public struct Result: Equatable, Sendable {
        public var active: [ShortcutAction]
        public var errors: [String]
    }

    public static func build(actions input: [ShortcutAction], showModsKey: String) -> Result {
        var actions = input
        let copyItemShortcut = KeyNames.mergeHotkeys("Ctrl + C", showModsKey)
        if copyItemShortcut != "Ctrl + C" {
            actions.append(ShortcutAction(shortcut: copyItemShortcut, action: .testOnly))
        }

        var allShortcuts: Set<String> = [
            "Ctrl + C", "Ctrl + V", "Ctrl + A", "Ctrl + F", "Ctrl + Enter",
            "Home", "Delete", "Enter", "ArrowUp", "ArrowRight", "ArrowLeft", copyItemShortcut,
        ]
        var errors: [String] = []
        for action in actions where allShortcuts.contains(action.shortcut) && !action.action.isTestOnly {
            errors.append("error [Shortcuts] Hotkey \"\(action.shortcut)\" reserved by the game will not be registered.")
        }
        actions = actions.filter { !allShortcuts.contains($0.shortcut) }

        var duplicates: Set<String> = []
        for action in actions {
            if allShortcuts.contains(action.shortcut) {
                errors.append("error [Shortcuts] It is not possible to use the same hotkey \"\(action.shortcut)\" for multiple actions.")
                duplicates.insert(action.shortcut)
            } else {
                allShortcuts.insert(action.shortcut)
            }
        }
        let active = actions.filter { !duplicates.contains($0.shortcut) || $0.action.isToggleOverlay }
        return Result(active: active, errors: errors)
    }
}

/// One synthesized key event.
public struct KeyStep: Equatable, Sendable {
    public var key: String
    public var down: Bool
    public init(_ key: String, down: Bool) {
        self.key = key
        self.down = down
    }
}

public enum KeySequences {
    /// Keys to release right after a hotkey fires (`Shortcuts.ts:189-201`): with `keepModKeys`
    /// only the main key, otherwise every key in reverse order.
    public static func releaseAfterHotkey(_ shortcut: String, keepModKeys: Bool) -> [KeyStep] {
        let parts = shortcut.components(separatedBy: " + ")
        if keepModKeys {
            return parts.filter { !KeyNames.isModifier($0) }.prefix(1).map { KeyStep($0, down: false) }
        }
        return parts.reversed().map { KeyStep($0, down: false) }
    }

    /// The copy chord pressed down before tapping C, and released 10 ms after
    /// (`pressKeysToCopyItemText`, `Shortcuts.ts:293-324`).
    public static func copyItemModifiers(showModsKey: String) -> [String] {
        KeyNames.mergeHotkeys("Ctrl + C", showModsKey)
            .components(separatedBy: " + ")
            .filter { $0 != "C" }
    }

    /// Which copy-chord modifiers to press, given those the user is still holding (hold-mode
    /// hotkeys keep their modifiers, e.g. Alt in `Alt + D`).
    ///
    /// Upstream re-presses held modifiers on macOS (`Shortcuts.ts:299-306`), a workaround for the
    /// native client. Under Wine that is unnecessary and harmful: the extra Option press/release
    /// while the user holds Option looks like a double-tap to other apps (seen: Claude Desktop's
    /// quick entry opened). With `retoggleHeld == false`, held modifiers are not pressed again;
    /// they stay in the flags of every synthesized event, so the game still sees them.
    public static func copyItemModifiersToPress(showModsKey: String, heldModifiers: Set<String>, retoggleHeld: Bool) -> [String] {
        copyItemModifiers(showModsKey: showModsKey).filter { retoggleHeld || !heldModifiers.contains($0) }
    }

    /// Modifiers the user keeps holding after a hotkey fires: all of them with `keepModKeys`, none otherwise
    /// (the others are released right after the hotkey, `releaseAfterHotkey`).
    public static func heldModifiers(after shortcut: String, keepModKeys: Bool) -> Set<String> {
        guard keepModKeys else { return [] }
        return Set(shortcut.components(separatedBy: " + ").filter(KeyNames.isModifier))
    }
}

extension KeyNames {
    /// Port of `mergeTwoHotkeys` (`ipc/KeyToCode.ts:247-252`).
    public static func mergeHotkeys(_ first: String, _ second: String) -> String {
        var seen: [String] = []
        for key in first.components(separatedBy: " + ") + second.components(separatedBy: " + ") where !seen.contains(key) {
            seen.append(key)
        }
        return hotkeyString(keys: seen)
    }
}
