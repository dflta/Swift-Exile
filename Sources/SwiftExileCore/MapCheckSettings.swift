import Foundation

/// Exiled Exchange 2's map check settings (`item-check` widget ▸ `maps`, map-check/common.ts): three
/// profiles, and for each rated modifier a decision per profile, stored as "d--" (one character
/// per profile: d deadly, w warning, g good, s seen, - none).
public struct MapCheckSettings: Equatable, Sendable {
    public var profile: Int
    public var showNewStats: Bool
    public var decisions: [String: String]

    public static let empty = MapCheckSettings(profile: 1, showNewStats: false, decisions: [:])

    /// This profile's decision for a modifier ("d", "w", "g", "s", or "-").
    public func decision(for matcher: String) -> Character {
        guard let set = decisions[matcher] else { return "-" }
        let index = max(0, min(2, profile - 1))
        let characters = Array(set)
        return characters.indices.contains(index) ? characters[index] : "-"
    }

    /// Clicking a modifier cycles none → deadly → warning → good → seen → none (`nextDecision`).
    public static func next(after decision: Character) -> Character {
        switch decision {
        case "d": return "w"
        case "w": return "g"
        case "g": return "s"
        default: return "d"
        }
    }
}

extension OverlaySettings {
    public var mapCheck: MapCheckSettings {
        guard case .object(let maps)? = widget("item-check")?["maps"] else { return .empty }
        var decisions: [String: String] = [:]
        if case .array(let entries)? = maps["selectedStats"] {
            for case .object(let entry) in entries {
                if let matcher = Self.string(entry["matcher"]), let decision = Self.string(entry["decision"]) {
                    decisions[matcher] = decision
                }
            }
        }
        return MapCheckSettings(profile: Int(Self.number(maps["profile"]) ?? 1),
                                showNewStats: Self.bool(maps["showNewStats"], default: false),
                                decisions: decisions)
    }

    /// Sets this profile's decision for a modifier, keeping the other profiles' (`decisionCreate`).
    public mutating func setMapDecision(_ decision: Character, for matcher: String) {
        updateMaps { maps in
            let profile = max(1, min(3, Int(Self.number(maps["profile"]) ?? 1)))
            var entries: [JSONValue] = []
            if case .array(let list)? = maps["selectedStats"] { entries = list }
            let index = entries.firstIndex {
                if case .object(let entry) = $0 { return Self.string(entry["matcher"]) == matcher }
                return false
            }
            var set: [Character] = Array("---")
            if let index, case .object(let entry) = entries[index], let existing = Self.string(entry["decision"]) {
                set = Array(existing.padding(toLength: 3, withPad: "-", startingAt: 0))
            }
            set[profile - 1] = decision
            let updated = JSONValue.object(["matcher": .string(matcher), "decision": .string(String(set))])
            if let index { entries[index] = updated } else { entries.append(updated) }
            maps["selectedStats"] = .array(entries)
        }
    }

    public mutating func setMapProfile(_ profile: Int) {
        updateMaps { $0["profile"] = .number(Double(max(1, min(3, profile)))) }
    }

    public mutating func setMapShowNewStats(_ value: Bool) {
        updateMaps { $0["showNewStats"] = .bool(value) }
    }

    private mutating func updateMaps(_ change: (inout [String: JSONValue]) -> Void) {
        updateWidget("item-check") { widget in
            var maps: [String: JSONValue] = [:]
            if case .object(let existing)? = widget["maps"] { maps = existing }
            if maps["profile"] == nil { maps["profile"] = .number(1) }
            change(&maps)
            widget["maps"] = .object(maps)
        }
    }
}
