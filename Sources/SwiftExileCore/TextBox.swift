import CoreGraphics
import Foundation

/// One step of a chat or stash-search macro: put text on the clipboard, or tap a key with
/// modifiers held.
public enum TextBoxStep: Equatable, Sendable {
    case setClipboard(String)
    case tap(String, modifiers: [String] = [])
}

/// Port of `main/src/shortcuts/text-box.ts`: the key sequences for "paste in chat" and stash search.
public enum TextBox {
    static let placeholderLast = "@last"
    /// Chat prefixes that pick a channel by themselves (`AUTO_CLEAR`, text-box.ts:7-14).
    static let autoClear: Set<Character> = ["#", "%", "@", "$", "&", "/"]

    /// `typeInChat` (text-box.ts:16-55).
    /// - Parameter command: the game's command modifier: "Ctrl" for the Windows client (under Wine),
    ///   "Meta" (⌘) for the native macOS client, as upstream uses on darwin.
    public static func typeInChat(_ text: String, send: Bool, command: String) -> [TextBoxStep] {
        var steps: [TextBoxStep] = []
        if text.hasPrefix(placeholderLast) {
            // "@last hello": reply to the last whisper (Ctrl+Enter opens it).
            steps.append(.setClipboard(String(text.dropFirst(placeholderLast.count + 1))))
            steps.append(.tap("Enter", modifiers: [command]))
        } else if text.hasSuffix(placeholderLast) {
            // "/invite @last": open the last whisper, then replace "@name" at the start.
            steps.append(.setClipboard(String(text.dropLast(placeholderLast.count))))
            steps.append(.tap("Enter", modifiers: [command]))
            steps.append(.tap("Home"))
            // Twice, to focus the input when using a controller.
            steps.append(.tap("Home"))
            steps.append(.tap("Delete"))
        } else {
            steps.append(.setClipboard(text))
            steps.append(.tap("Enter"))
            if let first = text.first, !autoClear.contains(first) {
                steps.append(.tap("A", modifiers: [command]))
            }
        }
        steps.append(.tap("V", modifiers: [command]))
        if send {
            steps.append(.tap("Enter"))
            // Restore the last chat.
            steps.append(.tap("Enter"))
            steps.append(.tap("ArrowUp"))
            steps.append(.tap("ArrowUp"))
            steps.append(.tap("Escape"))
        }
        return steps
    }

    /// `stashSearch` (text-box.ts:57-72): Ctrl+F (also on macOS), paste, Enter.
    public static func stashSearch(_ text: String, command: String) -> [TextBoxStep] {
        [
            .setClipboard(text),
            .tap("F", modifiers: ["Ctrl"]),
            .tap("V", modifiers: [command]),
            .tap("Enter"),
        ]
    }

    /// How long the game gets to read the clipboard before it's restored (`RESTORE_AFTER`,
    /// HostClipboard.ts:10). Wine reads the macOS clipboard through its own bridge, so it gets longer.
    public static func restoreDelay(isWine: Bool) -> Duration {
        isWine ? .milliseconds(300) : .milliseconds(120)
    }
}

/// Ctrl + mouse wheel switches stash tabs (`Shortcuts.ts:96-106`, `isStashArea` :326-337).
public enum StashScroll {
    /// Over the stash itself the game scrolls tabs on its own; elsewhere SwiftExile taps arrow keys.
    /// - Parameters:
    ///   - point: mouse location (Quartz, origin top-left).
    ///   - game: the game's drawable area (Quartz).
    public static func isStashArea(_ point: CGPoint, game: CGRect) -> Bool {
        // Upstream's uiSidebarWidth: the left panel is 370 px wide at 800×600 (GameWindow.ts:27-31).
        let sidebarWidth = (game.height * 370 / 600).rounded()
        guard point.x <= game.minX + sidebarWidth else { return false }
        return point.y > game.minY + game.height * 154 / 1600 && point.y < game.minY + game.height * 1192 / 1600
    }

    /// Wheel toward you (down) → next tab, away → previous. `physicalDelta` is the wheel's direction
    /// with the system's natural-scrolling setting undone: negative = toward you.
    public static func arrowKey(physicalDelta: Double) -> String? {
        if physicalDelta < 0 { return "ArrowRight" }
        if physicalDelta > 0 { return "ArrowLeft" }
        return nil
    }

    /// At most one tab switch per this interval: a trackpad sends many wheel events per swipe, and
    /// too many key presses can get you kicked for "Too many actions".
    public static let minimumInterval: TimeInterval = 0.12
}
