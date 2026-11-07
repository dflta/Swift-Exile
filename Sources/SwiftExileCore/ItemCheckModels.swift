import Foundation

/// The native item check's data, from the engine's `itemInfo` (upstream's ItemInfo.vue plus the
/// item's modifiers as the game describes them).
public enum ItemCheckResult: Decodable, Equatable, Sendable {
    /// A map, contract, or logbook: Exiled Exchange 2's map check shows it instead.
    case mapLike
    case item(ItemCheck)

    private enum CodingKeys: String, CodingKey { case mapLike }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .mapLike) == true {
            self = .mapLike
        } else {
            self = .item(try ItemCheck(from: decoder))
        }
    }
}

public struct ItemCheck: Decodable, Equatable, Sendable {
    public struct Links: Decodable, Equatable, Sendable {
        public var wiki: String
        public var poedb: String?
        public var craftOfExile: String?
    }

    public struct Weapon: Decodable, Equatable, Sendable {
        public var physicalDps: Int?
        public var elementalDps: Int?
        public var totalDps: Int
        public var attacksPerSecond: Double
        public var critChance: Double?
    }

    public struct Defences: Decodable, Equatable, Sendable {
        public var armour: Int?
        public var evasion: Int?
        public var energyShield: Int?
        public var ward: Int?
        public var block: Int?
    }

    public struct Requirements: Decodable, Equatable, Sendable {
        public var level: Int
        public var str: Int
        public var dex: Int
        public var int: Int
    }

    /// One "{ … }" block: the modifier's kind, name, tier, and the lines it adds.
    public struct Modifier: Decodable, Equatable, Sendable {
        /// Upstream's ModifierType: "explicit", "implicit", "rune", "enchant", "fractured", "desecrated"…
        public var type: String
        /// "prefix", "suffix", "corrupted", "eldritch", "mutated", or nil.
        public var generation: String?
        public var name: String?
        public var tier: Int?
        public var rank: Int?
        public var tags: [String]
        public var lines: [String]
    }

    public var item: PriceCheckItem
    /// A magic or rare item's own name ("Oblivion Strike"); `item.name` is then its base type.
    public var title: String?
    public var links: Links
    /// Stash search text for this item (its name, quoted).
    public var stashSearch: String
    /// Stash search text for items with the same price note (and name), when the item has a note.
    public var samePricedSearch: String?
    public var note: String?
    public var weapon: Weapon?
    public var defences: Defences?
    public var requires: Requirements?
    /// "Level 11 Bone Blast" for each skill the item grants.
    public var skills: [String]?
    public var mods: [Modifier]
    /// False when Exiled Exchange 2's parser doesn't know the item (quest items…): only the name,
    /// a wiki link, and a stash search are available.
    public var known: Bool?
    public var mirrored: Bool
    public var fractured: Bool
    public var sanctified: Bool
}

/// Splits a modifier line from advanced item text into the parts to draw: the rolled values and,
/// separately, the "(min-max)" range the game shows after each one.
public enum ModLineText {
    public struct Segment: Equatable, Sendable {
        public var text: String
        public var isRange: Bool

        public init(_ text: String, isRange: Bool = false) {
            self.text = text
            self.isRange = isRange
        }
    }

    public static func segments(_ line: String) -> [Segment] {
        // "24(20-24)%", "+5(5-7)", "-3(-5--2)", "1.5(1.2-1.8)".
        let pattern = #"\((-?\d+(?:\.\d+)?)[-–](-?\d+(?:\.\d+)?)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [Segment(line)] }
        var result: [Segment] = []
        var last = line.startIndex
        let ns = line as NSString
        for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: line) else { continue }
            if last < range.lowerBound { result.append(Segment(String(line[last..<range.lowerBound]))) }
            result.append(Segment(String(line[range]), isRange: true))
            last = range.upperBound
        }
        if last < line.endIndex { result.append(Segment(String(line[last...]))) }
        return result.isEmpty ? [Segment(line)] : result
    }
}
