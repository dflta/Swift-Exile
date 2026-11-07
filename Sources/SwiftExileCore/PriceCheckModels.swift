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
    public var decimal: Bool
}

public struct StatFilter: Decodable, Equatable, Sendable, Identifiable {
    public var index: Int
    public var text: String
    /// `text` with the rolled value filled in, e.g. "41% increased Evasion Rating".
    public var display: String
    public var tag: String
    public var hidden: String?
    public var disabled: Bool
    public var roll: StatRoll?
    public var id: Int { index }
}

public struct NinjaPrice: Decodable, Equatable, Sendable {
    public var min: Double
    public var max: Double
    public var currency: String
    public var url: String?
}

public struct FilterPresetInfo: Decodable, Equatable, Sendable {
    public var id: String
    public var active: Bool
}

/// Result of `check(clipboard)`.
public struct PriceCheck: Decodable, Equatable, Sendable {
    public var item: PriceCheckItem
    /// "trade" (item search) or "bulk" (currency exchange).
    public var api: String
    public var searchByDefault: Bool
    public var league: String?
    public var presets: [FilterPresetInfo]
    public var stats: [StatFilter]
    public var ninja: NinjaPrice?
}

/// Result of `setStat` / `selectPreset`.
public struct StatsUpdate: Decodable, Equatable, Sendable {
    public var stats: [StatFilter]
    public var api: String
}

public struct TradeListing: Decodable, Equatable, Sendable, Identifiable {
    public var price: Double
    public var currency: String
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
