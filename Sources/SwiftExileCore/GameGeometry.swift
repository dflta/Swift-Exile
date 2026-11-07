import CoreGraphics

/// What AX reports about the game window (plan §2.2).
public struct GameWindowGeometry: Equatable, Sendable {
    /// Window frame in global top-left ("Quartz") coordinates, as AX returns it.
    public var frame: CGRect
    /// True when the window has a title bar (AX close button present).
    public var isTitled: Bool
    /// `AXFullScreen`: native macOS fullscreen Space.
    public var isNativeFullScreen: Bool

    public init(frame: CGRect, isTitled: Bool, isNativeFullScreen: Bool) {
        self.frame = frame
        self.isTitled = isTitled
        self.isNativeFullScreen = isNativeFullScreen
    }

    /// The game's drawable area in Quartz coordinates.
    ///
    /// Replaces electron-overlay-window's `hasTitleBarOnMac`, which always subtracted a title bar
    /// (`dist/index.js:168-178`). Here the title bar is removed only for titled, non-fullscreen
    /// windows. Wine's borderless "fullscreen" has no close button, so it is untitled and the
    /// content is the whole frame.
    public func contentRect(titleBarHeight: CGFloat) -> CGRect {
        guard isTitled, !isNativeFullScreen, frame.height > titleBarHeight else { return frame }
        return CGRect(
            x: frame.minX,
            y: frame.minY + titleBarHeight,
            width: frame.width,
            height: frame.height - titleBarHeight
        )
    }
}

public enum ScreenCoordinates {
    /// Converts a Quartz rect (origin top-left of the primary display, y down) to Cocoa
    /// (origin bottom-left of the primary display, y up). `primaryHeight` is the height of the
    /// screen with the menu bar (`NSScreen.screens[0]`).
    public static func cocoaRect(fromQuartz rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Point conversion, used for mouse positions sent to the renderer.
    public static func quartzPoint(fromCocoa point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}
