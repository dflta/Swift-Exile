import CoreGraphics
import Foundation
import Testing
@testable import SwiftExileCore

@Suite struct PriceCheckModelTests {
    // Shape produced by Engine/engine.ts check() for the Snakebite gloves.
    static let checkJSON = #"""
    {"item":{"name":"Snakebite","refName":"Snakebite","namespace":"UNIQUE","icon":"https://web.poecdn.com/x.png","rarity":"Unique","category":"Gloves","itemLevel":75,"quality":null,"gemLevel":null,"stackSize":null,"corrupted":false,"unidentified":false},
     "api":"trade","searchByDefault":true,"league":"Forbidden Rites",
     "presets":[{"id":"filters.preset_exact","label":"Exact","active":true}],
     "itemFilters":[{"key":"corrupted","kind":"logical","label":"Not Corrupted","value":null,"max":null,"disabled":true},
                    {"key":"itemLevel","kind":"numeric","label":"Item Level","value":75,"max":null,"disabled":true}],
     "searchName":{"exact":"Snakebite","relaxed":null,"relaxedEnabled":false},
     "trade":{"listingType":"available","listed":null,"currency":null},
     "stats":[{"index":0,"text":"#% increased Evasion Rating","display":"41% increased Evasion Rating","tag":"explicit","hidden":null,"disabled":true,"tiers":[{"tier":1,"kind":"tier-1"}],
               "roll":{"value":41,"min":40,"max":null,"defaultMin":40,"defaultMax":60,"boundsMin":40,"boundsMax":60,"decimal":false}},
              {"index":1,"text":"Targets can be affected by +1 of your Poisons at the same time","display":"Targets can be affected by +1 of your Poisons at the same time","tag":"explicit","hidden":null,"disabled":true,"tiers":[],"roll":null}],
     "ninja":{"min":0.1,"max":0.1,"currency":"div","currencyIcon":null,"url":null,"trend":[0,1.5,null,2,3,4,5],"totalChange":15}}
    """#

    @Test func decodesCheck() throws {
        let check = try EngineJSON.decode(PriceCheck.self, from: Self.checkJSON)
        #expect(check.item.name == "Snakebite")
        #expect(check.item.rarity == "Unique")
        #expect(check.filters.api == "trade")
        #expect(check.filters.presets.first?.label == "Exact")
        #expect(check.filters.itemFilters.map(\.key) == ["corrupted", "itemLevel"])
        #expect(check.filters.itemFilters[1].kind == .numeric)
        #expect(check.filters.trade.listingType == "available")
        let stats = check.filters.stats
        #expect(stats.count == 2)
        #expect(stats[0].tiers == [StatTier(tier: 1, kind: "tier-1")])
        #expect(stats[0].roll?.min == 40)
        #expect(stats[0].roll?.max == nil)
        #expect(stats[1].roll == nil)
        #expect(check.ninja?.currency == "div")
        #expect(check.ninja?.trend?.count == 7)
        #expect(check.ninja?.forecast == .up) // +15 % over 7 days
    }

    @Test func forecastFollowsTotalChange() {
        func forecast(_ change: Double?) -> NinjaPrice.Forecast? {
            NinjaPrice(min: 1, max: 1, currency: "div", trend: [0, 1], totalChange: change).forecast
        }
        #expect(forecast(38) == .up)
        #expect(forecast(-4) == .down)
        #expect(forecast(1.5) == .steady)
        #expect(forecast(nil) == nil)
    }

    @Test func rollRangeMatchesUpstreamSlider() throws {
        let roll = StatRoll(value: 41, min: 40, max: nil, defaultMin: 40, defaultMax: 60, boundsMin: 30, boundsMax: 50, boundsKind: "tier", decimal: false)
        let range = try #require(RollRange(roll: roll))
        #expect(range.mode == .min)
        #expect(range.fraction(of: 41) == 0.55)
        #expect(range.selection == 0.5...1)
        #expect(range.value(at: 0.56, roundingUp: false) == 41) // 41.2 floors to 41
        #expect(range.value(at: 0.56, roundingUp: true) == 42)
        #expect(range.value(at: -1, roundingUp: false) == 30)
        var both = range
        both.max = 45
        #expect(both.mode == .range)
        both.min = 46 // entered the wrong way round: still drawn as one connected range
        #expect(both.mode == .range)
        #expect(both.selection == 0.75...0.8)
        // Bounds in either order give the same track.
        let negative = try #require(RollRange(roll: StatRoll(value: -1, min: nil, max: nil, defaultMin: -1, defaultMax: -1, boundsMin: -1, boundsMax: -5, boundsKind: "unique", decimal: false)))
        #expect(negative.lower == -5 && negative.upper == -1)
        #expect(negative.fraction(of: -1) == 1)
        #expect(RollRange.round(1.234, decimal: true, up: false) == 1.23)
        #expect(RollRange.round(5.55, decimal: true, up: true) == 5.6)
        #expect(RollRange.format(1.5) == "1.5")
        #expect(RollRange.format(40) == "40")
        // No bounds: no slider.
        #expect(RollRange(roll: StatRoll(value: 1, min: nil, max: nil, defaultMin: 1, defaultMax: 1, boundsMin: nil, boundsMax: nil, boundsKind: nil, decimal: false)) == nil)
    }

    @Test func engineErrorsThrow() {
        #expect(throws: EngineError(error: "item.unknown")) {
            try EngineJSON.decode(PriceCheck.self, from: #"{"error":"item.unknown"}"#)
        }
    }

    @Test func decodesTradeResults() throws {
        let json = #"{"api":"trade","total":1396,"inexact":false,"listings":[{"price":1,"currency":"vaal","currencyIcon":"https://web.poecdn.com/v.png","normalizedPrice":"0.2","normalizedCurrency":"chaos","listed":"3 days ago","account":"someone","status":"online","listedTimes":1,"instantBuyout":true,"itemLevel":"75","stackSize":null,"corrupted":false,"isMine":false}]}"#
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
