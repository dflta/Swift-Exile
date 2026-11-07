/// Key names in upstream's shortcut grammar (`ipc/KeyToCode.ts`) and the macOS virtual key codes
/// (`kVK_*` from Carbon's Events.h) they correspond to.
public enum KeyNames {
    /// macOS virtual key code → upstream key name.
    public static let byMacKeyCode: [UInt16: String] = {
        var map: [UInt16: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
            40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
            32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
            36: "Enter", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape", 57: "CapsLock",
            114: "Insert", 115: "Home", 116: "PageUp", 117: "Delete", 119: "End", 121: "PageDown",
            123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
            82: "Numpad0", 83: "Numpad1", 84: "Numpad2", 85: "Numpad3", 86: "Numpad4",
            87: "Numpad5", 88: "Numpad6", 89: "Numpad7", 91: "Numpad8", 92: "Numpad9",
            67: "NumpadMultiply", 69: "NumpadAdd", 78: "NumpadSubtract", 65: "NumpadDecimal", 75: "NumpadDivide",
            41: "Semicolon", 24: "Equal", 43: "Comma", 27: "Minus", 47: "Period", 44: "Slash",
            50: "Backquote", 33: "BracketLeft", 42: "Backslash", 30: "BracketRight", 39: "Quote",
        ]
        let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in functionKeys.enumerated() { map[code] = "F\(index + 1)" }
        return map
    }()

    public static func isModifier(_ key: String) -> Bool {
        key == "Ctrl" || key == "Shift" || key == "Alt"
    }

    /// Port of `hotkeyToString` (`ipc/KeyToCode.ts:227-245`).
    public static func hotkeyString(keys: [String], ctrl: Bool = false, shift: Bool = false, alt: Bool = false) -> String {
        let ctrl = ctrl || keys.contains("Ctrl")
        let shift = shift || keys.contains("Shift")
        let alt = alt || keys.contains("Alt")
        let plain = keys.filter { !isModifier($0) }

        var mod = ""
        if ctrl && shift && alt { mod = "Ctrl + Shift + Alt" }
        else if shift && alt { mod = "Shift + Alt" }
        else if ctrl && shift { mod = "Ctrl + Shift" }
        else if ctrl && alt { mod = "Ctrl + Alt" }
        else if alt { mod = "Alt" }
        else if ctrl { mod = "Ctrl" }
        else if shift { mod = "Shift" }

        if !mod.isEmpty && !plain.isEmpty { return "\(mod) + \(plain.joined(separator: " + "))" }
        let joined = plain.joined(separator: " + ")
        return joined.isEmpty ? mod : joined
    }

    /// Hotkey string for a key press inside the overlay, as `handleExtraCommands` builds it
    /// (`OverlayWindow.ts:134-153`). Nil for keys outside upstream's grammar.
    public static func hotkeyString(macKeyCode: UInt16, ctrl: Bool, shift: Bool, alt: Bool) -> String? {
        guard let name = byMacKeyCode[macKeyCode] else { return nil }
        return hotkeyString(keys: [name], ctrl: ctrl, shift: shift, alt: alt)
    }
}
