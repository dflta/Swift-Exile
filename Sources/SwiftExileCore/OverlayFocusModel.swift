/// Port of the overlay state machine in upstream `main/src/windowing/OverlayWindow.ts`, combined
/// with electron-overlay-window's macOS show/hide behavior (`dist/index.js:45-87`).
///
/// Pure value type: inputs come from the window tracker, the renderer, and hotkeys; outputs are
/// effects that the app applies to the panel and the event hub.
public struct OverlayFocusModel: Equatable, Sendable {
    public enum Effect: Equatable, Sendable {
        case broadcastOverlayAttached
        case broadcastFocusChange(game: Bool, overlay: Bool, usingHotkey: Bool)
        /// Interactable: panel takes mouse and keyboard. Not interactable: click-through.
        case setInteractable(Bool)
        /// Give keyboard focus back to the game.
        case focusGame
        case show
        case hide
    }

    public private(set) var isAttached = false
    public private(set) var isInteractable = false
    /// Upstream `GameWindow.isActive`: game is frontmost and the overlay does not have focus.
    public private(set) var gameActive = false
    public private(set) var gameFrontmost = false
    public private(set) var overlayIsKey = false
    public private(set) var isVisible = false
    public private(set) var shouldShowOverlay = true
    public private(set) var hideOverlayOnBlur = false
    private var isOverlayKeyUsed = false

    public init() {}

    public mutating func attached() -> [Effect] {
        isAttached = true
        return [.broadcastOverlayAttached] + syncVisibility()
    }

    public mutating func detached() -> [Effect] {
        isAttached = false
        gameFrontmost = false
        return setGameActive(false) + syncVisibility()
    }

    /// From the tracker: is the game the frontmost app, and does our panel hold keyboard focus?
    public mutating func focusChanged(gameFrontmost: Bool, overlayIsKey: Bool) -> [Effect] {
        self.gameFrontmost = gameFrontmost
        self.overlayIsKey = overlayIsKey
        return setGameActive(gameFrontmost && !overlayIsKey) + syncVisibility()
    }

    /// `assertOverlayActive` (`OverlayWindow.ts:94-103`).
    public mutating func assertOverlayActive() -> [Effect] {
        guard !isInteractable else { return [] }
        isInteractable = true
        var effects: [Effect] = syncVisibility()
        effects.append(.setInteractable(true))
        effects += setGameActive(false)
        return effects + syncVisibility()
    }

    /// `assertGameActive` (`OverlayWindow.ts:105-113`).
    public mutating func assertGameActive() -> [Effect] {
        guard isInteractable else { return [] }
        isInteractable = false
        var effects: [Effect] = [.setInteractable(false), .focusGame]
        if gameFrontmost { effects += setGameActive(true) }
        return effects + syncVisibility()
    }

    /// `toggleActiveState` (`OverlayWindow.ts:115-122`).
    public mutating func toggle() -> [Effect] {
        isOverlayKeyUsed = true
        return isInteractable ? assertGameActive() : assertOverlayActive()
    }

    /// `OVERLAY->MAIN::render-state` (`OverlayWindow.ts:38-41`).
    public mutating func renderState(shouldShow: Bool) -> [Effect] {
        shouldShowOverlay = shouldShow
        return syncVisibility()
    }

    public mutating func setHideOverlayOnBlur(_ value: Bool) -> [Effect] {
        hideOverlayOnBlur = value
        return syncVisibility()
    }

    /// `handlePoeWindowActiveChange` (`OverlayWindow.ts:192-206`), emitted only on change
    /// like the `GameWindow.isActive` setter (`GameWindow.ts:20-25`).
    private mutating func setGameActive(_ active: Bool) -> [Effect] {
        guard active != gameActive else { return [] }
        gameActive = active
        var effects: [Effect] = []
        if active && isInteractable {
            isInteractable = false
            effects.append(.setInteractable(false))
        }
        effects.append(.broadcastFocusChange(game: active, overlay: isInteractable, usingHotkey: isOverlayKeyUsed))
        isOverlayKeyUsed = false
        return effects
    }

    /// Visible while the game or the overlay has focus. With `hideOverlayOnBlur`, also hidden
    /// when the renderer has nothing to show (`OverlayWindow.ts:208-219`).
    private mutating func syncVisibility() -> [Effect] {
        let interactableAndFocused = isInteractable && (gameFrontmost || overlayIsKey)
        let gameShowing = gameActive && (!hideOverlayOnBlur || shouldShowOverlay)
        let shouldBeVisible = isAttached && (interactableAndFocused || gameShowing)
        guard shouldBeVisible != isVisible else { return [] }
        isVisible = shouldBeVisible
        return [shouldBeVisible ? .show : .hide]
    }
}
