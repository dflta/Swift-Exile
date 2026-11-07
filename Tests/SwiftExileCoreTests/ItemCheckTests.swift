import Foundation
import Testing
@testable import SwiftExileCore

@Suite struct ItemCheckTests {
    // Shape produced by Engine/engine.ts itemInfo() for a rare bow.
    static let bowJSON = #"""
    {"item":{"name":"Rider Bow","refName":"Rider Bow","namespace":"ITEM","icon":"https://web.poecdn.com/bow.png","rarity":"Rare","category":"Bow","itemLevel":80,"quality":null,"gemLevel":null,"stackSize":null,"corrupted":false,"unidentified":false},
     "title":"Oblivion Strike",
     "links":{"wiki":"https://www.poe2wiki.net/wiki/Rider_Bow","poedb":"https://poe2db.tw/us/Bows#ModifiersCalc","craftOfExile":null},
     "stashSearch":"\"Rider Bow\"","samePricedSearch":null,"note":null,
     "weapon":{"physicalDps":58,"elementalDps":103,"totalDps":161,"attacksPerSecond":1.2,"critChance":5},
     "defences":null,"requires":{"level":51,"str":0,"dex":103,"int":0},
     "mods":[{"type":"explicit","generation":"prefix","name":"Shocking","tier":4,"rank":null,"tags":["Damage","Elemental","Lightning","Attack"],"lines":["Adds 5(1-5) to 82(62-89) Lightning Damage"]},
             {"type":"explicit","generation":"suffix","name":"of Radiance","tier":1,"rank":null,"tags":[],"lines":["+57(41-60) to Accuracy Rating","15% increased Light Radius"]}],
     "mirrored":false,"fractured":false,"sanctified":false}
    """#

    @Test func decodesAnItem() throws {
        let result = try EngineJSON.decode(ItemCheckResult.self, from: Self.bowJSON)
        guard case .item(let check) = result else {
            Issue.record("expected an item")
            return
        }
        #expect(check.title == "Oblivion Strike")
        #expect(check.item.name == "Rider Bow")
        #expect(check.weapon?.totalDps == 161)
        #expect(check.requires?.dex == 103)
        #expect(check.links.craftOfExile == nil)
        #expect(check.mods.count == 2)
        #expect(check.mods[1].generation == "suffix" && check.mods[1].tier == 1 && check.mods[1].lines.count == 2)
    }

    @Test func mapsGoToTheOverlay() throws {
        #expect(try EngineJSON.decode(ItemCheckResult.self, from: #"{"mapLike":true}"#) == .mapLike)
    }

    @Test func engineErrorsThrow() {
        #expect(throws: EngineError.self) { try EngineJSON.decode(ItemCheckResult.self, from: #"{"error":"item.unknown"}"#) }
    }

    @Test func unknownItemsHaveOnlyTheBasics() throws {
        let json = #"""
        {"known":false,"item":{"name":"Kabala Clan Relic","refName":"Kabala Clan Relic","namespace":"","icon":"","rarity":"Quest","category":"Quest Items","itemLevel":null,"quality":null,"gemLevel":null,"stackSize":null,"corrupted":false,"unidentified":false},
         "title":null,"links":{"wiki":"https://www.poe2wiki.net/wiki/Kabala_Clan_Relic","poedb":null,"craftOfExile":null},
         "stashSearch":"\"Kabala Clan Relic\"","samePricedSearch":null,"note":null,"weapon":null,"defences":null,"requires":null,
         "skills":[],"mods":[],"mirrored":false,"fractured":false,"sanctified":false}
        """#
        guard case .item(let check) = try EngineJSON.decode(ItemCheckResult.self, from: json) else {
            Issue.record("expected an item")
            return
        }
        #expect(check.known == false)
        #expect(check.links.wiki.hasSuffix("Kabala_Clan_Relic"))
    }

    @Test func splitsRollRanges() {
        typealias S = ModLineText.Segment
        #expect(ModLineText.segments("Adds 5(1-5) to 82(62-89) Lightning Damage") ==
                [S("Adds 5"), S("(1-5)", isRange: true), S(" to 82"), S("(62-89)", isRange: true), S(" Lightning Damage")])
        #expect(ModLineText.segments("7.9(6-10) Life Regeneration per second") ==
                [S("7.9"), S("(6-10)", isRange: true), S(" Life Regeneration per second")])
        #expect(ModLineText.segments("-3(-5--2) to Level of all Skills") ==
                [S("-3"), S("(-5--2)", isRange: true), S(" to Level of all Skills")])
        #expect(ModLineText.segments("15% increased Light Radius") == [S("15% increased Light Radius")])
    }
}
