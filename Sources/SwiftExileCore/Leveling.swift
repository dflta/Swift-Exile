import Foundation

/// What the native experience tracker needs from the game log (port of the relevant parts of
/// upstream's `client-log-parser.ts`).
public enum ClientLogEvent: Equatable, Sendable {
    case zone(name: String, areaLevel: Int)
    case levelUp(character: String, characterClass: String, level: Int)
}

public enum ClientLogParser {
    /// `LogRegex` (client-log.ts): date, time, millis, source, `[LEVEL Client N]`, text.
    private static let line = try! NSRegularExpression(
        pattern: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} \d+ [a-f0-9]+ \[\S+ \S+ \S+\] (.*)$"#)
    /// `LOG_ZONE_GEN`: the same English text in every client language.
    private static let zone = try! NSRegularExpression(
        pattern: #"^Generating level (\d+) area "(.*)" with seed \d+$"#)
    /// `LOG_LEVEL_UP` from every language's client_strings.js (groups: name, class, level).
    private static let levelUps: [NSRegularExpression] = [
        #"^(.*) \((.*)\) is now level (\d+)$"#,                    // en
        #"^(.*) \((.*)\) ist jetzt Stufe (\d+)$"#,                  // de
        #"^(.*) \((.*)\) es ahora nivel (\d+)$"#,                   // es
        #"^(.*) \((.*)\) vient de passer au niveau (\d+).$"#,       // fr
        #"^(.*) \((.*)\) chegou ao nível (\d+)$"#,                  // pt
        #"^(.*) \((.*)\) достигает (\d+) уровня$"#,                 // ru
        #"^(.*) \((.*)\) 現在等級 (\d+)$"#,                          // cmn-Hant
        #"^(.*) \((.*)\)は現在レベル(\d+)です$"#,                      // ja
        #"^(.*) \((.*)\)의 레벨이 (\d+)이\(가\) 되었습니다$"#,          // ko
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func parse(_ text: String) -> ClientLogEvent? {
        guard let body = capture(line, in: text)?.first else { return nil }
        if body.hasPrefix(":") {
            // A message shown to the player, e.g. ": Name (Class) is now level 18".
            let message = body.dropFirst().trimmingCharacters(in: .whitespaces)
            for pattern in levelUps {
                if let groups = capture(pattern, in: message), groups.count == 3, let level = Int(groups[2]) {
                    return .levelUp(character: groups[0], characterClass: groups[1], level: level)
                }
            }
            return nil
        }
        if body.hasPrefix("Generating level"), let groups = capture(zone, in: body), let level = Int(groups[0]) {
            return .zone(name: groups[1], areaLevel: level)
        }
        return nil
    }

    private static func capture(_ regex: NSRegularExpression, in text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

/// Experience penalty math, ported from upstream's `WidgetXpTracker.vue`.
public enum ExperiencePenalty {
    /// Levels below your own that monsters can be before the under-level penalty starts.
    public static func safeZone(playerLevel: Int) -> Int { playerLevel / 16 + 3 }

    /// "Over": how far your level is above the bottom of the safe zone (0–1 is ideal).
    public static func overIdeal(playerLevel: Int, areaLevel: Int) -> Int {
        safeZone(playerLevel: playerLevel) - (areaLevel - playerLevel)
    }

    /// Experience you get, in percent (1–100).
    public static func multiplier(playerLevel: Int, areaLevel: Int) -> Double {
        let safe = areaLevel > playerLevel ? safeZone(playerLevel: playerLevel) : 0
        let effectiveDiff = Double(max(abs(areaLevel - playerLevel) - safe, 0))
        let player = Double(playerLevel)
        return 100 * max(0.01, pow((player + 5) / (player + 5 + pow(effectiveDiff, 2.5)), 1.3))
    }
}

/// The tracker's state: your level and the last area you entered.
public struct LevelingState: Equatable, Sendable {
    public var playerLevel: Int?
    public var character: String?
    public var areaLevel: Int?
    public var zone: String?

    public init(playerLevel: Int? = nil, character: String? = nil, areaLevel: Int? = nil, zone: String? = nil) {
        self.playerLevel = playerLevel
        self.character = character
        self.areaLevel = areaLevel
        self.zone = zone
    }

    /// Towns and hideouts don't change the area level (as upstream: they say nothing about where
    /// you're farming).
    public mutating func apply(_ event: ClientLogEvent) {
        switch event {
        case .zone(let name, let level):
            let lower = name.lowercased()
            guard !lower.contains("town"), !lower.contains("hideout") else { return }
            if lower == "g1_1" { playerLevel = 1 } // the first zone: a new character
            zone = name
            areaLevel = level
        case .levelUp(let name, _, let level):
            character = name
            playerLevel = level
        }
    }

    public mutating func apply(lines: [String]) {
        for line in lines { if let event = ClientLogParser.parse(line) { apply(event) } }
    }

    public var penalty: Double? {
        guard let playerLevel, let areaLevel else { return nil }
        return ExperiencePenalty.multiplier(playerLevel: playerLevel, areaLevel: areaLevel)
    }

    public var over: Int? {
        guard let playerLevel, let areaLevel else { return nil }
        return ExperiencePenalty.overIdeal(playerLevel: playerLevel, areaLevel: areaLevel)
    }

    /// Reads the end of the log (up to `maxBytes`) so the tracker starts with your current level
    /// and zone instead of waiting for the next level-up (upstream starts empty).
    public static func fromHistory(path: String, maxBytes: Int = 16 * 1024 * 1024) -> LevelingState {
        var state = LevelingState()
        guard let handle = FileHandle(forReadingAtPath: path) else { return state }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return state }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return state }
        // "\r\n" line endings (Windows client): split on any newline, not just "\n".
        var lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if start > 0, !lines.isEmpty { lines.removeFirst() } // probably cut in half
        state.apply(lines: lines)
        return state
    }
}
