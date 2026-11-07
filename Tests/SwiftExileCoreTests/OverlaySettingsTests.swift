import Foundation
import Testing
@testable import SwiftExileCore

@Suite struct OverlaySettingsTests {
    static let sample = #"""
    {"configVersion":35,"overlayKey":"Shift + Space","restoreClipboard":true,"stashScroll":true,"readClientLog":false,
     "windowTitle":"Path of Exile 2","language":"en","logKeys":false,"hideOverlayOnBlur":false,"enableAlphas":false,"alphas":[],
     "clientLog":null,"gameConfig":null,"futureUpstreamOption":{"keep":"me"},
     "commands":[{"text":"/hideout","hotkey":"F5","send":true},{"text":"@last ty","hotkey":null,"send":true}],
     "widgets":[
       {"wmId":1,"wmType":"price-check","hotkey":"D","hotkeyHold":"Alt","hotkeyLocked":"Ctrl + D","initialDelay":48,"searchStatRange":10},
       {"wmId":2,"wmType":"item-check","hotkey":null,"wikiKey":"Alt + W"},
       {"wmId":3,"wmType":"stash-search","enableHotkeys":true,"entries":[{"id":1,"name":"Uniques","text":"rarity: unique","hotkey":"F6"}]},
       {"wmId":4,"wmType":"stash-search","enableHotkeys":false,"entries":[{"id":1,"name":"Off","text":"x","hotkey":"F7"}]},
       {"wmId":5,"wmType":"delve-grid","toggleKey":null}
     ]}
    """#

    @Test func hostConfigMatchesUpstreamDerivation() throws {
        let settings = try #require(OverlaySettings(json: Self.sample))
        let host = settings.hostConfig()
        let shortcuts = host.shortcuts.compactMap(ShortcutAction.init(json:))
        #expect(shortcuts.map(\.shortcut) == ["Alt + D", "Ctrl + D", "Shift + Space", "Alt + W", "F5", "F6"])
        #expect(shortcuts[0] == ShortcutAction(shortcut: "Alt + D", keepModKeys: true, action: .copyItem(target: "price-check", focusOverlay: false)))
        #expect(shortcuts[1].action == .copyItem(target: "price-check", focusOverlay: true))
        #expect(shortcuts[4].action == .pasteInChat(text: "/hideout", send: true))
        #expect(shortcuts[5].action == .stashSearch(text: "rarity: unique"))
        #expect(host.restoreClipboard && host.stashScroll && !host.readClientLog)
        #expect(host.initialDelay == 48)
    }

    @Test func editsKeepUnknownKeys() throws {
        var settings = try #require(OverlaySettings(json: Self.sample))
        settings[bool: "readClientLog"] = true
        var commands = settings.commands
        commands[1].hotkey = "F8"
        commands.append(.init(text: "/exit", hotkey: "F9", send: true))
        settings.commands = commands
        settings.updateWidget("price-check") { $0["hotkeyLocked"] = .string("Ctrl + Shift + D") }
        var entries = settings.stashSearchEntries(widgetID: 3)
        entries[0].text = "rarity: rare"
        settings.setStashSearchEntries(entries, widgetID: 3)

        let reloaded = try #require(OverlaySettings(json: settings.serialized()))
        #expect(reloaded.root["futureUpstreamOption"] == .object(["keep": .string("me")]))
        #expect(reloaded[bool: "readClientLog"])
        #expect(reloaded.commands.map(\.hotkey) == ["F5", "F8", "F9"])
        #expect(OverlaySettings.string(reloaded.widget("price-check")?["hotkeyLocked"]) == "Ctrl + Shift + D")
        #expect(reloaded.stashSearchEntries(widgetID: 3).first?.text == "rarity: rare")
        #expect(reloaded.stashSearchEntries(widgetID: 4).first?.text == "x") // the other widget untouched
        #expect(reloaded.widgets("stash-search").count == 2)
    }

    @Test func describesWhatUsesAHotkey() throws {
        let settings = try #require(OverlaySettings(json: #"""
        {"overlayKey":"Shift + Space","commands":[{"text":"/hideout","hotkey":"F5","send":true}],
         "widgets":[{"wmType":"price-check","wmId":1,"hotkey":"D","hotkeyHold":"Alt","hotkeyLocked":"Ctrl + D"},
                    {"wmType":"item-check","wmId":2,"hotkey":"Shift + T","wikiKey":"Shift + T"}]}
        """#))
        let uses = settings.hotkeyUses()
        #expect(uses["Alt + D"] == ["Price check"])
        #expect(uses["Ctrl + D"] == ["Price check (without auto-hide)"])
        #expect(uses["F5"] == ["Chat command “/hideout”"])
        #expect(Set(uses["Shift + T"] ?? []) == ["Item check", "Open on the wiki"])
        #expect(uses["Shift + Space"] == ["Overlay"])
    }
}
