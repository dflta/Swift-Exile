import Foundation

/// Decides whether to take keyboard focus back after the game grabbed it (risk R6).
///
/// Under Wine (seen with NotProton/CrossOver 27) the game sometimes takes key focus back right
/// after the overlay takes it, depending on the game's state rather than on SwiftExile. The overlay
/// first takes focus without activating SwiftExile, so the game stays frontmost. If the game takes
/// it back shortly afterwards, retake it a bounded number of times; the last attempt also activates
/// SwiftExile, as Electron's `window.focus()` does. After that, give up: the focus model then drops
/// the overlay back to click-through.
public struct FocusReclaimPolicy: Sendable, Equatable {
    public enum Decision: Equatable, Sendable {
        case none
        case retake(activateApp: Bool)
        /// Out of attempts; report once.
        case giveUp
    }

    public var window: TimeInterval
    public var maxAttempts: Int
    public private(set) var interactableSince: Date?
    public private(set) var attempts = 0
    public private(set) var reportedGiveUp = false

    public init(window: TimeInterval = 1.5, maxAttempts: Int = 3) {
        self.window = window
        self.maxAttempts = maxAttempts
    }

    /// The overlay just became interactable.
    public mutating func began(at date: Date) {
        interactableSince = date
        attempts = 0
        reportedGiveUp = false
    }

    /// The overlay is no longer interactable.
    public mutating func ended() {
        interactableSince = nil
    }

    /// Called on every focus change while the model may still think the overlay is interactable.
    public mutating func decide(now: Date, isInteractable: Bool, panelIsKey: Bool, gameFrontmost: Bool) -> Decision {
        guard isInteractable, !panelIsKey, gameFrontmost, let since = interactableSince else { return .none }
        guard now.timeIntervalSince(since) < window else { return .none }
        if attempts < maxAttempts {
            attempts += 1
            return .retake(activateApp: attempts == maxAttempts)
        }
        if !reportedGiveUp {
            reportedGiveUp = true
            return .giveUp
        }
        return .none
    }
}
