import Carbon.HIToolbox
import CoreGraphics

/// Which key (and whether Shift) types each character in the current keyboard layout, so text can be
/// typed key by key. Wine turns the keys back into characters with the same layout. Keypad keys and
/// dead keys (e.g. ' and " on US International) are left out.
struct KeyboardLayoutMap {
    struct Key: Equatable {
        var code: CGKeyCode
        var shift: Bool
    }

    let keys: [Character: Key]

    static func current() -> KeyboardLayoutMap? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var keys: [Character: Key] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for shift in [false, true] {
                let modifiers = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
                for code in 0..<128 where !(65...92).contains(code) { // not the keypad
                    var deadState: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers,
                                                UInt32(LMGetKbdType()), 0, &deadState, 4, &length, &characters)
                    guard status == noErr, deadState == 0, length == 1,
                          let character = String(utf16CodeUnits: characters, count: length).first,
                          keys[character] == nil
                    else { continue }
                    keys[character] = Key(code: CGKeyCode(code), shift: shift)
                }
            }
        }
        return KeyboardLayoutMap(keys: keys)
    }

    /// The keys for `text`, or nil when the layout can't type one of its characters.
    func keys(for text: String) -> [Key]? {
        var result: [Key] = []
        for character in text {
            guard let key = keys[character] else { return nil }
            result.append(key)
        }
        return result
    }
}
