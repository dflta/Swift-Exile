import Foundation

/// Recognizes item text copied from the game (`isPoeItem`, `HostClipboard.ts:110-173`).
public enum ItemTextDetector {
    /// First line of copied item text per game language, plus the line uncut skill gems start with.
    static let languages: [(lang: String, firstLine: String, uncutSkillGemLine: String)] = [
        ("en", "Item Class: ", "Rarity: "),
        ("ru", "Класс предмета: ", "Редкость: "),
        ("fr", "Classe d'objet: ", "Rareté: "),
        ("de", "Gegenstandsklasse: ", "Seltenheit: "),
        ("pt", "Classe do Item: ", "Raridade: "),
        ("es", "Clase de objeto: ", "Rareza: "),
        ("th", "ชนิดไอเทม: ", "Rarity: "),
        ("ko", "아이템 종류: ", "아이템 희귀도: "),
        ("cmn-Hant", "物品種類: ", "稀有度: "),
        ("cmn-Hans", "物品类别: ", "Rarity: "),
        ("ja", "アイテムクラス: ", "レアリティ: "),
    ]

    public static func isItem(_ text: String) -> Bool {
        languages.contains { text.hasPrefix($0.firstLine) || text.hasPrefix($0.uncutSkillGemLine) }
    }
}

/// Clipboard access, abstracted for tests.
public protocol PasteboardAccess: Sendable {
    func readString() async -> String?
    func writeString(_ value: String) async
}

/// Port of `HostClipboard.readItemText` (`HostClipboard.ts:31-83`).
///
/// Clears the clipboard if it already holds an item, waits `initialDelay`, then polls every
/// 48 ms for up to 500 ms for new item text, optionally restoring what was there before.
/// Concurrent calls share one poll, like upstream's `pollPromise`.
public actor ItemClipboardPoller {
    public enum PollError: Error, Equatable { case timedOut }

    public static let pollDelay: Duration = .milliseconds(48)
    public static let pollLimit: Duration = .milliseconds(500)

    private let pasteboard: PasteboardAccess
    private let sleep: @Sendable (Duration) async -> Void
    private var running: Task<String, Error>?
    public var restoreClipboard = false
    public var initialDelay: Duration = .milliseconds(48)
    /// Extra polling time on top of the 500 ms limit (Wine's clipboard bridge may be slower, R12).
    public var extraPollTime: Duration = .zero

    public init(pasteboard: PasteboardAccess, sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.pasteboard = pasteboard
        self.sleep = sleep
    }

    public func configure(restoreClipboard: Bool, initialDelayMs: Double) {
        self.restoreClipboard = restoreClipboard
        self.initialDelay = .milliseconds(Int(max(0, initialDelayMs)))
    }

    public func setExtraPollTime(_ value: Duration) { extraPollTime = value }

    public var isPolling: Bool { running != nil }

    /// - Parameter afterPrepare: runs once the old clipboard state is saved and cleared, before
    ///   polling starts. The caller presses the copy keys here, so the game's copy can't land
    ///   before the old item is cleared (upstream does both synchronously).
    public func readItemText(afterPrepare: @Sendable () async -> Void = {}) async throws -> String {
        if let running {
            await afterPrepare()
            return try await running.value
        }

        var textBefore = await pasteboard.readString() ?? ""
        if ItemTextDetector.isItem(textBefore) {
            // So the old item isn't mistaken for the new copy (HostClipboard.ts:37-41).
            textBefore = ""
            await pasteboard.writeString("")
        }
        await afterPrepare()

        let task = Task { [pasteboard, sleep, restoreClipboard, initialDelay, extraPollTime] () throws -> String in
            await sleep(initialDelay)
            var elapsed: Duration = .zero
            let limit = Self.pollLimit + extraPollTime
            while true {
                let text = await pasteboard.readString() ?? ""
                if ItemTextDetector.isItem(text) {
                    if restoreClipboard { await pasteboard.writeString(textBefore) }
                    return text
                }
                elapsed += Self.pollDelay
                if elapsed >= limit {
                    if restoreClipboard { await pasteboard.writeString(textBefore) }
                    throw PollError.timedOut
                }
                await sleep(Self.pollDelay)
            }
        }
        running = task
        defer { running = nil }
        return try await task.value
    }
}

/// Reads the game's settings file (`GameConfig.ts`).
public enum GameConfigReader {
    /// Minimal INI parser: `[SECTION]` headers and `key=value` lines. Keys keep their first value.
    public static func parse(_ contents: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current = ""
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = String(rawLine)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                continue
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if sections[current]?[key] == nil {
                sections[current, default: [:]][key] = value
            }
        }
        return sections
    }

    /// `parseConfigHotkey` (`GameConfig.ts:99-134`): `"18"` → `"Alt"`, `"67 2"` → `"Ctrl + C"`.
    /// Modifier codes: 1 = Shift, 2 = Ctrl, 3 = Alt.
    public static func parseHotkey(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.split(separator: " ").map(String.init)
        guard let code = Int(parts[0]), let key = KeyNames.nameForWindowsVirtualKey[code] else { return nil }
        var ctrl = false, shift = false, alt = false
        if parts.count > 1 {
            switch parts[1] {
            case "1": shift = true
            case "2": ctrl = true
            case "3": alt = true
            default: return nil
            }
        }
        return KeyNames.hotkeyString(keys: [key], ctrl: ctrl, shift: shift, alt: alt)
    }

    /// The game's "show advanced item descriptions" key, which upstream adds to the copy chord.
    /// Defaults to `"Alt"` like upstream (`GameConfig.ts:50-52`).
    public static func showModsKey(iniContents: String?) -> (key: String, fromFile: Bool) {
        guard let iniContents,
              let parsed = parseHotkey(parse(iniContents)["ACTION_KEYS"]?["show_advanced_item_descriptions"])
        else { return ("Alt", false) }
        return (parsed, true)
    }
}
