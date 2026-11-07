import CoreGraphics
import Foundation
import Testing
@testable import SwiftExileCore

@Suite struct PriceCheckModelTests {
    // Shape produced by Engine/engine.ts check() for the Snakebite gloves.
    static let checkJSON = #"""
    {"item":{"name":"Snakebite","refName":"Snakebite","namespace":"UNIQUE","icon":"https://web.poecdn.com/x.png","rarity":"Unique","category":"Gloves","itemLevel":75,"quality":null,"gemLevel":null,"stackSize":null,"corrupted":false,"unidentified":false},
     "api":"trade","searchByDefault":true,"league":"Forbidden Rites",
     "presets":[{"id":"filters.preset_exact","active":true}],
     "stats":[{"index":0,"text":"#% increased Evasion Rating","display":"41% increased Evasion Rating","tag":"explicit","hidden":null,"disabled":true,
               "roll":{"value":41,"min":40,"max":null,"defaultMin":40,"defaultMax":60,"boundsMin":40,"boundsMax":60,"decimal":false}},
              {"index":1,"text":"Targets can be affected by +1 of your Poisons at the same time","display":"Targets can be affected by +1 of your Poisons at the same time","tag":"explicit","hidden":null,"disabled":true,"roll":null}],
     "ninja":{"min":0.1,"max":0.1,"currency":"div","url":null}}
    """#

    @Test func decodesCheck() throws {
        let check = try EngineJSON.decode(PriceCheck.self, from: Self.checkJSON)
        #expect(check.item.name == "Snakebite")
        #expect(check.item.rarity == "Unique")
        #expect(check.stats.count == 2)
        #expect(check.stats[0].roll?.min == 40)
        #expect(check.stats[0].roll?.max == nil)
        #expect(check.stats[1].roll == nil)
        #expect(check.ninja == NinjaPrice(min: 0.1, max: 0.1, currency: "div", url: nil))
    }

    @Test func engineErrorsThrow() {
        #expect(throws: EngineError(error: "item.unknown")) {
            try EngineJSON.decode(PriceCheck.self, from: #"{"error":"item.unknown"}"#)
        }
    }

    @Test func decodesTradeResults() throws {
        let json = #"{"api":"trade","total":1396,"inexact":false,"listings":[{"price":1,"currency":"vaal","normalizedPrice":"0.2","normalizedCurrency":"chaos","listed":"3 days ago","account":"someone","status":"online","listedTimes":1,"instantBuyout":true,"itemLevel":"75","stackSize":null,"corrupted":false,"isMine":false}]}"#
        let results = try EngineJSON.decode(SearchResults.self, from: json)
        guard case .trade(let total, _, let listings) = results else { Issue.record("not trade"); return }
        #expect(total == 1396)
        #expect(listings.first?.currency == "vaal")
    }

    @Test func decodesBulkResults() throws {
        let json = #"{"api":"bulk","groups":[{"have":"divine","total":12,"listings":[{"exchangeAmount":1,"itemAmount":150,"stock":900,"listed":"1 hour ago","account":"a","status":"online","isMine":false}]}]}"#
        let results = try EngineJSON.decode(SearchResults.self, from: json)
        guard case .bulk(let groups) = results else { Issue.record("not bulk"); return }
        #expect(groups.first?.have == "divine")
        #expect(abs((groups.first?.listings.first?.pricePerItem ?? 0) - 1.0 / 150) < 1e-9)
    }

    @Test func placementAvoidsItemSide() {
        let game = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let size = CGSize(width: 440, height: 900)
        // Item in the inventory (right half): panel left of the inventory panel.
        let right = PriceCheckPlacement.frame(game: game, cursorX: 2200, size: size)
        #expect(right.maxX <= game.maxX - 1440 * 986 / 1600 + 0.5)
        // Item in the stash (left half): panel right of the stash panel.
        let left = PriceCheckPlacement.frame(game: game, cursorX: 300, size: size)
        #expect(abs(left.minX - 1440 * 986 / 1600) < 0.5)
        #expect(left.minY == 270)
    }
}
