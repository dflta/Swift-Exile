import CoreGraphics

/// Port of `main/src/windowing/WidgetAreaTracker.ts`: after a price check opens without focus,
/// moving the mouse away closes it, moving into it makes the overlay clickable.
public struct WidgetAreaModel: Equatable, Sendable {
    public struct Area: Equatable, Sendable {
        public var holdKey: String
        public var closeThreshold: Double
        public var from: CGPoint
        public var rect: CGRect

        public init(holdKey: String, closeThreshold: Double, from: CGPoint, rect: CGRect) {
            self.holdKey = holdKey
            self.closeThreshold = closeThreshold
            self.from = from
            self.rect = rect
        }
    }

    public enum Effect: Equatable, Sendable {
        case hideExclusiveWidget
        case activateOverlay
        case focusGame
    }

    public private(set) var area: Area?
    public var isTracking: Bool { area != nil }

    public init() {}

    /// `OVERLAY->MAIN::track-area`. On macOS upstream uses the coordinates as-is
    /// (`WidgetAreaTracker.ts:54-58`): CSS pixels equal points.
    public mutating func start(_ area: Area) { self.area = area }
    public mutating func stop() { area = nil }

    /// `handleMouseMove` (`WidgetAreaTracker.ts:71-88`).
    public mutating func mouseMoved(to point: CGPoint, ctrl: Bool, alt: Bool, overlayInteractable: Bool) -> [Effect] {
        guard let area else { return [] }
        let modifier: String? = ctrl ? "Ctrl" : (alt ? "Alt" : nil)
        if !overlayInteractable && modifier != area.holdKey {
            let distance = hypot(point.x - area.from.x, point.y - area.from.y)
            if distance > area.closeThreshold {
                stop()
                return [.hideExclusiveWidget]
            }
            return []
        }
        if Self.isInside(point, area.rect) {
            return [.activateOverlay]
        }
        if overlayInteractable {
            stop()
            return [.focusGame]
        }
        return []
    }

    /// `handleMouseDown` (`WidgetAreaTracker.ts:90-95`).
    public mutating func mouseDown(at point: CGPoint) -> [Effect] {
        guard let area, Self.isInside(point, area.rect) else { return [] }
        stop()
        return [.activateOverlay]
    }

    /// Strict inequalities, like `isPointInsideRect` (`WidgetAreaTracker.ts:98-105`).
    static func isInside(_ point: CGPoint, _ rect: CGRect) -> Bool {
        point.x > rect.minX && point.x < rect.maxX && point.y > rect.minY && point.y < rect.maxY
    }
}

/// Port of `main/src/windowing/OverlayVisibility.ts`: holding Alt alone hides the overlay so the
/// game's own advanced tooltip is readable; any other input shows it again.
public struct AltVisibilityModel: Equatable, Sendable {
    public enum Effect: Equatable, Sendable {
        case scheduleHide(milliseconds: Int)
        case cancelHide
        case broadcastVisible(Bool)
    }

    public private(set) var isOverlayVisible = true
    public private(set) var hidePending = false

    public init() {}

    /// Alt pressed with no other modifier (`OverlayVisibility.ts:15-22`).
    public mutating func altPressedAlone(overlayInteractable: Bool) -> [Effect] {
        guard isOverlayVisible, !hidePending else { return [] }
        hidePending = true
        return [.scheduleHide(milliseconds: overlayInteractable ? 85 : 275)]
    }

    /// Any other key, Alt release, or mouse move without Alt (`OverlayVisibility.ts:23-38`).
    public mutating func otherInput() -> [Effect] {
        if hidePending {
            hidePending = false
            return [.cancelHide]
        }
        guard !isOverlayVisible else { return [] }
        isOverlayVisible = true
        return [.broadcastVisible(true)]
    }

    public mutating func hideTimerFired() -> [Effect] {
        guard hidePending else { return [] }
        hidePending = false
        isOverlayVisible = false
        return [.broadcastVisible(false)]
    }
}
