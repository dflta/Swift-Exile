import Foundation

// Data returned by the headless price-check engine (Engine/engine.ts). Every engine call returns
// JSON; errors come back as `{"error": "..."}`.

public struct EngineError: Error, Equatable, Decodable, CustomStringConvertible {
    public var error: String
    public var description: String { error }
}

public struct EngineInfo: Decodable, Equatable, Sendable {
    public var language: String
    public var league: String?
}

public struct PriceCheckItem: Decodable, Equatable, Sendable {
    public var name: String
    public var refName: String
    public var namespace: String
    public var icon: String
    public var rarity: String?
    public var category: String?
    public var itemLevel: Int?
    public var quality: Int?
    public var gemLevel: Int?
    public var stackSize: Int?
    public var corrupted: Bool
    public var unidentified: Bool
}

public struct StatRoll: Decodable, Equatable, Sendable {
    public var value: Double
    public var min: Double?
    public var max: Double?
    public var defaultMin: Double
    public var defaultMax: Double
    public var boundsMin: Double?
    public var boundsMax: Double?
    /// "unique" (the unique's roll range, as upstream) or "tier" (the modifier tiers' range).
    public var boundsKind: String?
    public var decimal: Bool
}

public struct StatTier: Decodable, Equatable, Sendable, Hashable {
    public var tier: Int
    /// "tier-1", "tier-2", "tier-3-plus", or "not-tier-1" (FilterModifierTiers.vue).
    public var kind: String
}

public struct StatFilter: Decodable, Equatable, Sendable, Identifiable {
    public var index: Int
    public var text: String
    /// `text` with the rolled value filled in, e.g. "41% increased Evasion Rating".
    public var display: String
    public var tag: String
    public var hidden: String?
    public var disabled: Bool
    public var tiers: [StatTier]
    /// How many modifiers make up this filter (pseudo totals: "pseudo ×2").
    public var sources: Int?
    public var roll: StatRoll?
    public var id: Int { index }
}

/// A price range in one currency.
public struct PriceValue: Decodable, Equatable, Sendable {
    public var min: Double
    public var max: Double
    public var currency: String
    public var currencyIcon: String?
}

/// poe.ninja price for a number of items.
public struct StackPrice: Decodable, Equatable, Sendable {
    public var count: Int
    public var min: Double
    public var max: Double
    public var currency: String
    public var currencyIcon: String?
}

public struct NinjaPrice: Decodable, Equatable, Sendable {
    public var min: Double
    public var max: Double
    public var currency: String
    public var currencyIcon: String?
    /// Price of the whole stack (or the Stock filter's amount); nil for single items.
    public var stack: StackPrice?
    public var url: String?
    /// poe.ninja's 7-day sparkline: change in percent per day, oldest first (nil = no data).
    public var trend: [Double?]?
    public var totalChange: Double?

    public enum Forecast: String, Sendable { case up, down, steady }

    public init(min: Double, max: Double, currency: String, currencyIcon: String? = nil, url: String? = nil, trend: [Double?]? = nil, totalChange: Double? = nil) {
        self.min = min
        self.max = max
        self.currency = currency
        self.currencyIcon = currencyIcon
        self.stack = nil
        self.url = url
        self.trend = trend
        self.totalChange = totalChange
    }

    /// Direction of the 7-day change shown next to the graph, so the arrow, colour, and
    /// percentage agree (changes within ±2 % count as steady).
    public var forecast: Forecast? {
        guard let change = totalChange else { return nil }
        if change >= 2 { return .up }
        if change <= -2 { return .down }
        return .steady
    }
}

public struct FilterPresetInfo: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var active: Bool
}

/// An item-level filter (item level, quality, corrupted, ...), FiltersBlock.vue.
public struct ItemFilterChip: Decodable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Decodable, Sendable { case numeric, logical }
    public var key: String
    public var kind: Kind
    public var label: String
    public var value: Double?
    public var max: Double?
    public var disabled: Bool
    public var id: String { key }
}

/// Exact name vs. "Any <category>" (FilterName.vue).
public struct SearchName: Decodable, Equatable, Sendable {
    public var exact: String
    public var relaxed: String?
    public var relaxedEnabled: Bool
}

/// Currency poe.ninja prices are shown in (SwiftExile setting, stored in UserDefaults).
public enum PriceCurrency: String, CaseIterable, Sendable {
    case auto, chaos, exalted, divine

    public static let defaultsKey = "priceCurrency"

    public var label: String {
        switch self {
        case .auto: return "Automatic"
        case .chaos: return "Chaos Orb"
        case .exalted: return "Exalted Orb"
        case .divine: return "Divine Orb"
        }
    }
}

public struct TradeOptions: Decodable, Equatable, Sendable {
    public var listingType: String
    public var listed: String?
    public var currency: String?

    public static let listingTypes: [(id: String, label: String)] = [
        ("available", "Instant or Online"), ("securable", "Instant"), ("online", "Online"),
        ("onlineleague", "Online in League"), ("any", "Offline & Online"),
    ]
    public static let listedOptions: [(id: String?, label: String)] = [
        (nil, "Any time"), ("1day", "1 day"), ("3days", "3 days"), ("1week", "1 week"),
        ("2weeks", "2 weeks"), ("1month", "1 month"), ("2months", "2 months"),
    ]
    public static let currencies: [(id: String?, label: String)] = [
        (nil, "Any currency"), ("exalted", "Exalted Orb"), ("chaos", "Chaos Orb"), ("divine", "Divine Orb"),
    ]
}

/// Everything about the current filters; returned by `check` and after every change.
public struct FilterState: Decodable, Equatable, Sendable {
    /// "trade" (item search) or "bulk" (currency exchange).
    public var api: String
    public var presets: [FilterPresetInfo]
    public var stats: [StatFilter]
    public var itemFilters: [ItemFilterChip]
    public var searchName: SearchName
    public var trade: TradeOptions
}

public struct LeagueInfo: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
}

/// An augment (rune, soul core, ...) or catalyst the item editor offers.
public struct EditorEntry: Decodable, Equatable, Sendable, Identifiable {
    public var refName: String
    public var name: String
    public var icon: String
    public var text: String
    /// An augment that can't be removed from its socket.
    public var bound: Bool?
    public var id: String { refName }
}

public struct EditorTab: Decodable, Equatable, Sendable, Identifiable {
    /// "Rune", "Soul Core", "Idol", "Legacy", "Other".
    public var tab: String
    /// "Lesser", "Normal", "Greater", "Perfect", ... ("" when the tab has no groups).
    public var group: String
    public var items: [EditorEntry]
    public var id: String { "\(tab)/\(group)" }
}

/// Upstream's item editor (ItemEditorV2.vue): try runes in sockets, or a catalyst's quality.
public struct ItemEditorState: Decodable, Equatable, Sendable {
    /// "augment", "catalyst", or "none".
    public var type: String
    public var sockets: [EditorEntry?]?
    public var tabs: [EditorTab]?
    public var catalysts: [EditorEntry]?
    public var amounts: [Int]?
    public var selected: String?
    public var quality: Int?
    /// poe.ninja cost of the catalysts for the selected quality.
    public var price: PriceValue?
}

/// Result of `setAugment` / `setCatalyst`: new filters and editor state.
public struct EditResult: Decodable, Equatable, Sendable {
    public var filters: FilterState
    public var editor: ItemEditorState

    private enum CodingKeys: String, CodingKey { case editor }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        editor = try container.decode(ItemEditorState.self, forKey: .editor)
        filters = try FilterState(from: decoder)
    }
}

/// Result of `check(clipboard)`.
public struct PriceCheck: Decodable, Equatable, Sendable {
    public var item: PriceCheckItem
    public var searchByDefault: Bool
    public var league: String?
    /// Trade leagues to choose from.
    public var leagues: [LeagueInfo]
    public var ninja: NinjaPrice?
    public var editor: ItemEditorState?
    /// Icons of the trade currencies ("divine", "exalted", "chaos") for menus.
    public var currencyIcons: [String: String]
    public var filters: FilterState

    private enum CodingKeys: String, CodingKey { case item, searchByDefault, league, leagues, ninja, editor, currencyIcons }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        item = try container.decode(PriceCheckItem.self, forKey: .item)
        searchByDefault = try container.decode(Bool.self, forKey: .searchByDefault)
        league = try container.decodeIfPresent(String.self, forKey: .league)
        leagues = try container.decodeIfPresent([LeagueInfo].self, forKey: .leagues) ?? []
        ninja = try container.decodeIfPresent(NinjaPrice.self, forKey: .ninja)
        editor = try container.decodeIfPresent(ItemEditorState.self, forKey: .editor)
        currencyIcons = (try container.decodeIfPresent([String: String?].self, forKey: .currencyIcons) ?? [:]).compactMapValues { $0 }
        filters = try FilterState(from: decoder)
    }
}

public struct TradeLink: Decodable, Equatable, Sendable {
    public var url: String
}

public struct TradeListing: Decodable, Equatable, Sendable, Identifiable {
    public var price: Double
    public var currency: String
    public var currencyIcon: String?
    public var normalizedPrice: String?
    public var normalizedCurrency: String?
    public var listed: String
    public var account: String
    public var status: String
    public var listedTimes: Int
    public var instantBuyout: Bool
    public var itemLevel: String?
    public var stackSize: Int?
    public var corrupted: Bool
    public var isMine: Bool
    public var id: String { "\(account)|\(price)|\(currency)|\(listed)" }
}

public struct BulkListing: Decodable, Equatable, Sendable, Identifiable {
    public var exchangeAmount: Double
    public var itemAmount: Double
    public var stock: Int
    public var listed: String
    public var account: String
    public var status: String
    public var isMine: Bool
    public var id: String { "\(account)|\(exchangeAmount)|\(itemAmount)" }
    /// Price of one item in the group's currency.
    public var pricePerItem: Double { itemAmount > 0 ? exchangeAmount / itemAmount : 0 }
}

public struct BulkGroup: Decodable, Equatable, Sendable, Identifiable {
    /// Currency paid ("divine", "exalted", "chaos").
    public var have: String
    public var haveIcon: String?
    public var total: Int
    public var listings: [BulkListing]
    public var id: String { have }
}

public enum SearchResults: Decodable, Equatable, Sendable {
    case trade(total: Int, inexact: Bool, listings: [TradeListing])
    case bulk(groups: [BulkGroup])

    private enum CodingKeys: String, CodingKey { case api, total, inexact, listings, groups }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .api) {
        case "bulk":
            self = .bulk(groups: try container.decode([BulkGroup].self, forKey: .groups))
        default:
            self = .trade(
                total: try container.decode(Int.self, forKey: .total),
                inexact: try container.decodeIfPresent(Bool.self, forKey: .inexact) ?? false,
                listings: try container.decode([TradeListing].self, forKey: .listings)
            )
        }
    }
}

public enum EngineJSON {
    /// Decodes an engine response, turning `{"error": ...}` into `EngineError`.
    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let data = Data(text.utf8)
        if let failure = try? JSONDecoder().decode(EngineError.self, from: data) {
            throw failure
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Where the native price check goes, mirroring Exiled Exchange 2: next to the game's stash or
/// inventory panel, on the side away from the item (`PriceCheckWindow.vue`, `OverlayWindow.vue`).
public enum PriceCheckPlacement {
    /// - Parameters:
    ///   - game: the game's drawable area (Quartz, origin top-left).
    ///   - cursorX: where the item was (Quartz).
    ///   - size: panel size.
    public static func frame(game: CGRect, cursorX: CGFloat, size: CGSize) -> CGRect {
        // Upstream: the stash/inventory panel is 986 px wide at a height of 1600 px.
        let poePanelWidth = game.height * 986 / 1600
        let itemOnRight = cursorX - game.minX > game.width / 2
        let x = itemOnRight ? game.maxX - poePanelWidth - size.width : game.minX + poePanelWidth
        let y = game.minY + max(0, (game.height - size.height) / 2)
        return CGRect(x: max(game.minX, min(x, game.maxX - size.width)), y: y, width: size.width, height: min(size.height, game.height))
    }
}
