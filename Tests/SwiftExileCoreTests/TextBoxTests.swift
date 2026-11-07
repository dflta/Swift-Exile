import CoreGraphics
import Testing
@testable import SwiftExileCore

@Suite struct TextBoxTests {
    @Test func chatMessageReplacesWhatWasTyped() {
        #expect(TextBox.typeInChat("hello", send: false, command: "Ctrl") == [
            .setClipboard("hello"), .tap("Enter"), .tap("A", modifiers: ["Ctrl"]), .tap("V", modifiers: ["Ctrl"]),
        ])
    }

    @Test func channelPrefixKeepsInput() {
        // "#", "%", "@", ... pick a channel themselves: no select-all.
        #expect(TextBox.typeInChat("%party", send: false, command: "Ctrl") == [
            .setClipboard("%party"), .tap("Enter"), .tap("V", modifiers: ["Ctrl"]),
        ])
    }

    @Test func lastWhisperPrefix() {
        #expect(TextBox.typeInChat("@last thanks", send: true, command: "Meta") == [
            .setClipboard("thanks"), .tap("Enter", modifiers: ["Meta"]), .tap("V", modifiers: ["Meta"]),
            .tap("Enter"), .tap("Enter"), .tap("ArrowUp"), .tap("ArrowUp"), .tap("Escape"),
        ])
    }

    @Test func lastWhisperSuffix() {
        #expect(TextBox.typeInChat("/invite @last", send: false, command: "Ctrl") == [
            .setClipboard("/invite "), .tap("Enter", modifiers: ["Ctrl"]), .tap("Home"), .tap("Home"), .tap("Delete"),
            .tap("V", modifiers: ["Ctrl"]),
        ])
    }

    @Test func stashSearchUsesCtrlF() {
        #expect(TextBox.stashSearch("rarity: unique", command: "Meta") == [
            .setClipboard("rarity: unique"), .tap("F", modifiers: ["Ctrl"]), .tap("V", modifiers: ["Meta"]), .tap("Enter"),
        ])
    }

    @Test func stashArea() {
        let game = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        // Sidebar is 1440 * 370/600 = 888 px wide; stash rows between y 138.6 and 1072.8.
        #expect(StashScroll.isStashArea(CGPoint(x: 400, y: 600), game: game))
        #expect(!StashScroll.isStashArea(CGPoint(x: 1200, y: 600), game: game)) // right of the stash
        #expect(!StashScroll.isStashArea(CGPoint(x: 400, y: 100), game: game))  // tabs header
        #expect(!StashScroll.isStashArea(CGPoint(x: 400, y: 1200), game: game)) // below
        #expect(StashScroll.arrowKey(physicalDelta: -1) == "ArrowRight")
        #expect(StashScroll.arrowKey(physicalDelta: 2) == "ArrowLeft")
        #expect(StashScroll.arrowKey(physicalDelta: 0) == nil)
    }
}
