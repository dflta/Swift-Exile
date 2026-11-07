import CoreGraphics
import Foundation
import Testing
@testable import SwiftExileCore

@Suite struct HotkeyTests {
    @Test func parsesShortcutStrings() throws {
        let hotkey = try #require(Hotkey("Ctrl + Shift + D"))
        #expect(hotkey == Hotkey(key: "D", ctrl: true, shift: true))
        #expect(hotkey.macKeyCode == 2)
        #expect(Hotkey("Shift + Space")?.macKeyCode == 49)
        #expect(Hotkey("Alt") == nil) // modifier only
        #expect(Hotkey("Alt + D")?.string == "Alt + D")
    }

    @Test func modifierKeyCodes() {
        #expect(KeyNames.macKeyCode(for: "Ctrl") == 59)
        #expect(KeyNames.macKeyCode(for: "Alt") == 58)
        #expect(KeyNames.macKeyCode(for: "Shift") == 56)
        #expect(KeyNames.macKeyCode(for: "C") == 8)
    }

    @Test func mergeMatchesUpstream() {
        #expect(KeyNames.mergeHotkeys("Ctrl + C", "Alt") == "Ctrl + Alt + C")
        #expect(KeyNames.mergeHotkeys("Ctrl + C", "Ctrl") == "Ctrl + C")
        #expect(KeyNames.mergeHotkeys("Ctrl + C", "Shift + Alt") == "Ctrl + Shift + Alt + C")
    }

    @Test func decodesRendererShortcuts() throws {
        // Shape sent by getConfigForHost (Config.ts:692-716) for the dev Mac's settings.
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        [{"shortcut":"Alt + D","action":{"type":"copy-item","target":"price-check","focusOverlay":false},"keepModKeys":true},
         {"shortcut":"Ctrl + D","action":{"type":"copy-item","target":"price-check","focusOverlay":true}},
         {"shortcut":"Shift + Space","action":{"type":"toggle-overlay"}}]
        """#.utf8))
        guard case .array(let items) = json else { Issue.record("not an array"); return }
        let actions = items.compactMap(ShortcutAction.init(json:))
        #expect(actions.count == 3)
        #expect(actions[0] == ShortcutAction(shortcut: "Alt + D", keepModKeys: true, action: .copyItem(target: "price-check", focusOverlay: false)))
        #expect(actions[1].action == .copyItem(target: "price-check", focusOverlay: true))
        #expect(actions[2].action == .toggleOverlay)
    }
}

@Suite struct ShortcutRegistryTests {
    @Test func dropsReservedAndKeepsOthers() {
        let result = ShortcutRegistry.build(actions: [
            ShortcutAction(shortcut: "Ctrl + C", action: .copyItem(target: "price-check", focusOverlay: false)),
            ShortcutAction(shortcut: "Alt + D", keepModKeys: true, action: .copyItem(target: "price-check", focusOverlay: false)),
            ShortcutAction(shortcut: "Shift + Space", action: .toggleOverlay),
        ], showModsKey: "Alt")
        #expect(result.active.map(\.shortcut) == ["Alt + D", "Shift + Space"])
        #expect(result.errors == ["error [Shortcuts] Hotkey \"Ctrl + C\" reserved by the game will not be registered."])
    }

    @Test func copyChordIsReservedAsTestOnly() {
        // With show-mods = Alt the copy chord is Ctrl + Alt + C; a user hotkey on it is rejected.
        let result = ShortcutRegistry.build(actions: [
            ShortcutAction(shortcut: "Ctrl + Alt + C", action: .triggerEvent(target: "x")),
        ], showModsKey: "Alt")
        #expect(result.active.isEmpty)
        #expect(result.errors.count == 1)
    }

    @Test func duplicatesAreDroppedExceptToggleOverlay() {
        let result = ShortcutRegistry.build(actions: [
            ShortcutAction(shortcut: "F5", action: .triggerEvent(target: "a")),
            ShortcutAction(shortcut: "F5", action: .toggleOverlay),
        ], showModsKey: "Alt")
        #expect(result.active.map(\.action) == [.toggleOverlay])
        #expect(result.errors.contains { $0.contains("same hotkey \"F5\"") })
    }
}

@Suite struct KeySequenceTests {
    @Test func releaseKeepsModifiersWhenAsked() {
        #expect(KeySequences.releaseAfterHotkey("Alt + D", keepModKeys: true) == [KeyStep("D", down: false)])
        #expect(KeySequences.releaseAfterHotkey("Ctrl + D", keepModKeys: false) == [KeyStep("D", down: false), KeyStep("Ctrl", down: false)])
    }

    @Test func holdModeDoesNotRepressHeldAltUnderWine() {
        // Alt + D with keepModKeys: the user keeps holding Alt.
        let held = KeySequences.heldModifiers(after: "Alt + D", keepModKeys: true)
        #expect(held == ["Alt"])
        #expect(KeySequences.copyItemModifiersToPress(showModsKey: "Alt", heldModifiers: held, retoggleHeld: false) == ["Ctrl"])
        // Native client keeps upstream's re-toggle.
        #expect(KeySequences.copyItemModifiersToPress(showModsKey: "Alt", heldModifiers: held, retoggleHeld: true) == ["Ctrl", "Alt"])
    }

    @Test func lockedHotkeyReleasesModifiersSoAllArePressed() {
        let held = KeySequences.heldModifiers(after: "Ctrl + D", keepModKeys: false)
        #expect(held.isEmpty)
        #expect(KeySequences.copyItemModifiersToPress(showModsKey: "Alt", heldModifiers: held, retoggleHeld: false) == ["Ctrl", "Alt"])
    }

    @Test func flavorDecidesRetoggle() {
        #expect(GameFlavor.native(bundleID: "x").retogglesHeldModifiers)
        #expect(!GameFlavor.wine(prefix: nil, installDir: nil).retogglesHeldModifiers)
        #expect(!GameFlavor.unknown.retogglesHeldModifiers)
    }

    @Test func copyChordUsesShowModsKey() {
        #expect(KeySequences.copyItemModifiers(showModsKey: "Alt") == ["Ctrl", "Alt"])
        #expect(KeySequences.copyItemModifiers(showModsKey: "Ctrl") == ["Ctrl"])
    }
}

@Suite struct GameConfigReaderTests {
    // Excerpt shaped like the dev Mac's poe2_production_Config.ini (BOM, key in two sections).
    let ini = "\u{FEFF}[DISPLAY]\r\nfullscreen=false\r\n[ACTION_KEYS]\r\nshow_advanced_item_descriptions=18\r\nuse_bound_skill1=1\r\n[CONTROLLER_ACTION_KEYS]\r\nshow_advanced_item_descriptions=99\r\n"

    @Test func readsShowModsKeyFromActionKeys() {
        let result = GameConfigReader.showModsKey(iniContents: ini)
        #expect(result.key == "Alt")
        #expect(result.fromFile)
    }

    @Test func parsesModifierCodes() {
        #expect(GameConfigReader.parseHotkey("67 2") == "Ctrl + C")
        #expect(GameConfigReader.parseHotkey("68 1") == "Shift + D")
        #expect(GameConfigReader.parseHotkey("68 3") == "Alt + D")
        #expect(GameConfigReader.parseHotkey("68 9") == nil)
        #expect(GameConfigReader.parseHotkey("9999") == nil)
    }

    @Test func defaultsToAlt() {
        #expect(GameConfigReader.showModsKey(iniContents: nil) == ("Alt", false))
        #expect(GameConfigReader.showModsKey(iniContents: "[DISPLAY]\nx=1") == ("Alt", false))
    }
}

@Suite struct ItemClipboardPollerTests {
    actor FakePasteboard: PasteboardAccess {
        var value: String?
        var writes: [String] = []
        var reads = 0
        /// After this many reads the "game" puts the item on the clipboard.
        var itemAfterReads: Int?
        let item: String

        init(initial: String?, item: String, itemAfterReads: Int?) {
            self.value = initial
            self.item = item
            self.itemAfterReads = itemAfterReads
        }

        func readString() -> String? {
            reads += 1
            if let threshold = itemAfterReads, reads > threshold { value = item }
            return value
        }

        func writeString(_ value: String) {
            self.value = value
            writes.append(value)
        }
    }

    static let item = "Item Class: Rings\r\nRarity: Rare\r\nGale Loop\r\nRuby Ring\r\n"

    @Test func detectsItemText() {
        #expect(ItemTextDetector.isItem(Self.item))
        #expect(ItemTextDetector.isItem("Rarity: Gem\nUncut Skill Gem"))
        #expect(!ItemTextDetector.isItem("hello"))
    }

    @Test func returnsItemAndRestoresClipboard() async throws {
        let pasteboard = FakePasteboard(initial: "my password", item: Self.item, itemAfterReads: 3)
        let poller = ItemClipboardPoller(pasteboard: pasteboard, sleep: { _ in })
        await poller.configure(restoreClipboard: true, initialDelayMs: 48)
        let text = try await poller.readItemText()
        #expect(text == Self.item)
        #expect(await pasteboard.writes == ["my password"])
    }

    @Test func clearsOldItemBeforePolling() async throws {
        let pasteboard = FakePasteboard(initial: Self.item, item: Self.item, itemAfterReads: 2)
        let poller = ItemClipboardPoller(pasteboard: pasteboard, sleep: { _ in })
        _ = try await poller.readItemText()
        #expect(await pasteboard.writes.first == "")
    }

    @Test func timesOutAfterLimit() async {
        let pasteboard = FakePasteboard(initial: "text", item: Self.item, itemAfterReads: nil)
        let poller = ItemClipboardPoller(pasteboard: pasteboard, sleep: { _ in })
        await #expect(throws: ItemClipboardPoller.PollError.timedOut) {
            try await poller.readItemText()
        }
        // 500 ms limit / 48 ms per poll → 11 polls, plus the initial read.
        #expect(await pasteboard.reads == 12)
    }
}

@Suite struct PointerModelTests {
    let area = WidgetAreaModel.Area(holdKey: "Alt", closeThreshold: 40, from: CGPoint(x: 1000, y: 500),
                                    rect: CGRect(x: 100, y: 0, width: 460, height: 1440))

    @Test func movingAwayClosesWidget() {
        var model = WidgetAreaModel()
        model.start(area)
        #expect(model.mouseMoved(to: CGPoint(x: 1010, y: 500), ctrl: false, alt: false, overlayInteractable: false) == [])
        #expect(model.mouseMoved(to: CGPoint(x: 1100, y: 500), ctrl: false, alt: false, overlayInteractable: false) == [.hideExclusiveWidget])
        #expect(!model.isTracking)
    }

    @Test func holdingHoldKeyKeepsWidgetAndEnteringActivates() {
        var model = WidgetAreaModel()
        model.start(area)
        #expect(model.mouseMoved(to: CGPoint(x: 700, y: 500), ctrl: false, alt: true, overlayInteractable: false) == [])
        #expect(model.mouseMoved(to: CGPoint(x: 300, y: 500), ctrl: false, alt: true, overlayInteractable: false) == [.activateOverlay])
        #expect(model.isTracking)
    }

    @Test func leavingWhileInteractableFocusesGame() {
        var model = WidgetAreaModel()
        model.start(area)
        #expect(model.mouseMoved(to: CGPoint(x: 900, y: 500), ctrl: false, alt: false, overlayInteractable: true) == [.focusGame])
        #expect(!model.isTracking)
    }

    @Test func clickInsideActivates() {
        var model = WidgetAreaModel()
        model.start(area)
        #expect(model.mouseDown(at: CGPoint(x: 900, y: 500)) == [])
        #expect(model.mouseDown(at: CGPoint(x: 300, y: 500)) == [.activateOverlay])
        #expect(!model.isTracking)
    }

    @Test func altAloneHidesAfterDelayAndOtherInputRestores() {
        var model = AltVisibilityModel()
        #expect(model.altPressedAlone(overlayInteractable: false) == [.scheduleHide(milliseconds: 275)])
        #expect(model.altPressedAlone(overlayInteractable: false) == [])
        #expect(model.hideTimerFired() == [.broadcastVisible(false)])
        #expect(model.otherInput() == [.broadcastVisible(true)])
        #expect(model.otherInput() == [])
    }

    @Test func quickReleaseCancelsHide() {
        var model = AltVisibilityModel()
        #expect(model.altPressedAlone(overlayInteractable: true) == [.scheduleHide(milliseconds: 85)])
        #expect(model.otherInput() == [.cancelHide])
        #expect(model.hideTimerFired() == [])
        #expect(model.isOverlayVisible)
    }
}
