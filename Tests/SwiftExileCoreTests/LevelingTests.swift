import Foundation
import Testing
@testable import SwiftExileCore

@Suite struct LevelingTests {
    @Test func parsesZonesAndLevelUps() {
        #expect(ClientLogParser.parse(#"2026/11/07 17:40:48 531229335 2caa22f9 [DEBUG Client 296] Generating level 18 area "G2_10_2" with seed 4169148378"#)
                == .zone(name: "G2_10_2", areaLevel: 18))
        #expect(ClientLogParser.parse("2026/11/07 17:38:02 531063852 3ef23348 [INFO Client 296] : You_Are_Sorceress (Sorceress) is now level 18")
                == .levelUp(character: "You_Are_Sorceress", characterClass: "Sorceress", level: 18))
        #expect(ClientLogParser.parse("2026/11/07 17:38:02 1 3ef23348 [INFO Client 296] : Gründer (Hexe) ist jetzt Stufe 7")
                == .levelUp(character: "Gründer", characterClass: "Hexe", level: 7))
        // Chat and anything else: nothing.
        #expect(ClientLogParser.parse("2026/11/07 17:42:35 531337046 3ef23348 [INFO Client 296] #raz_UNEARTH: inv pls") == nil)
        #expect(ClientLogParser.parse("not a log line") == nil)
    }

    @Test func penaltyMatchesUpstream() {
        // Values from upstream's formulas (the widget in the screenshot: level 17 in area 1).
        #expect(ExperiencePenalty.overIdeal(playerLevel: 17, areaLevel: 1) == 20)
        #expect(abs(ExperiencePenalty.multiplier(playerLevel: 17, areaLevel: 1) - 1.0) < 0.001)
        #expect(ExperiencePenalty.multiplier(playerLevel: 17, areaLevel: 18) == 100)
        #expect(ExperiencePenalty.overIdeal(playerLevel: 17, areaLevel: 18) == 3)
        #expect(ExperiencePenalty.multiplier(playerLevel: 18, areaLevel: 26) < 100) // beyond the safe zone
        #expect(ExperiencePenalty.multiplier(playerLevel: 18, areaLevel: 20) == 100)
    }

    @Test func townsDontChangeTheArea() {
        var state = LevelingState()
        state.apply(.levelUp(character: "A", characterClass: "B", level: 18))
        state.apply(.zone(name: "G2_10_2", areaLevel: 18))
        state.apply(.zone(name: "G2_town", areaLevel: 32))
        state.apply(.zone(name: "HideoutShoreline", areaLevel: 65))
        #expect(state.areaLevel == 18)
        #expect(state.zone == "G2_10_2")
        #expect(state.over == 4) // level 18: safe zone 18/16 + 3 = 4
    }

    @Test func startsFromHistory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftexile-history-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        2026/11/07 13:47:14 1 3ef23348 [INFO Client 296] : You_Are_Sorceress (Sorceress) is now level 16
        2026/11/07 17:29:41 2 2caa22f9 [DEBUG Client 296] Generating level 18 area "G2_10_2" with seed 1
        2026/11/07 17:38:02 3 3ef23348 [INFO Client 296] : You_Are_Sorceress (Sorceress) is now level 18
        2026/11/07 17:40:44 4 2caa22f9 [DEBUG Client 296] Generating level 32 area "G2_town" with seed 1

        """.write(to: url, atomically: true, encoding: .utf8)
        let state = LevelingState.fromHistory(path: url.path)
        #expect(state == LevelingState(playerLevel: 18, character: "You_Are_Sorceress", areaLevel: 18, zone: "G2_10_2"))

        // The same log with the Windows client's "\r\n" line endings.
        let crlf = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\n", with: "\r\n")
        try crlf.write(to: url, atomically: true, encoding: .utf8)
        #expect(LevelingState.fromHistory(path: url.path) == state)
    }
}
