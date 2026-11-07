import AppKit
import SwiftUI

/// Remembers a panel's top-left corner as a fraction of the game area, so it keeps its place when the
/// game window moves or changes resolution.
struct PanelPosition {
    let key: String

    func load() -> CGPoint? {
        guard let text = UserDefaults.standard.string(forKey: key) else { return nil }
        let point = NSPointFromString(text)
        return point == .zero ? nil : point
    }

    /// Top-left corner (Cocoa) for a panel of `size` in `game`, or nil when nothing was saved.
    func origin(size: CGSize, in game: CGRect) -> CGPoint? {
        guard let fraction = load() else { return nil }
        let x = game.minX + fraction.x * game.width
        let top = game.maxY - fraction.y * game.height
        // Keep it on the game even if the window got smaller.
        return CGPoint(x: min(max(x, game.minX), game.maxX - size.width),
                       y: min(max(top - size.height, game.minY), game.maxY - size.height))
    }

    func save(frame: CGRect, in game: CGRect) {
        guard game.width > 0, game.height > 0 else { return }
        let fraction = CGPoint(x: (frame.minX - game.minX) / game.width, y: (game.maxY - frame.maxY) / game.height)
        UserDefaults.standard.set(NSStringFromPoint(fraction), forKey: key)
    }
}

/// A small grab tab attached to the left of a panel (as a child window, so it moves with it).
/// Dragging the tab moves the panel; the panel's own content never shifts to make room for it.
@MainActor
final class FloatingHandle {
    enum Alignment { case center, top }

    private final class TabPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Moves `target` while the tab is dragged.
    private final class GripView: NSView {
        weak var target: NSWindow?
        var onDragEnded: (() -> Void)?
        private var start: (mouse: NSPoint, origin: NSPoint)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } // works without focus
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) {
            guard let target else { return }
            start = (NSEvent.mouseLocation, target.frame.origin)
            NSCursor.closedHand.push()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let target else { return }
            let now = NSEvent.mouseLocation
            target.setFrameOrigin(NSPoint(x: start.origin.x + now.x - start.mouse.x, y: start.origin.y + now.y - start.mouse.y))
        }

        override func mouseUp(with event: NSEvent) {
            NSCursor.pop()
            if start != nil { onDragEnded?() }
            start = nil
        }
    }

    private let tab: TabPanel
    private let grip: GripView
    private weak var target: NSWindow?
    private let alignment: Alignment
    static let size = CGSize(width: 26, height: 30)

    /// - Parameter onMoved: called when a drag ends (save the position here).
    init(attachedTo target: NSWindow, alignment: Alignment = .center, onMoved: @escaping () -> Void = {}) {
        self.target = target
        self.alignment = alignment
        tab = TabPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tab.isOpaque = false
        tab.backgroundColor = .clear
        tab.hasShadow = true
        tab.hidesOnDeactivate = false
        tab.isFloatingPanel = true
        tab.animationBehavior = .none
        tab.collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle]
        tab.level = target.level

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 7
        effect.layer?.masksToBounds = true
        effect.appearance = NSAppearance(named: .darkAqua)

        let icon = NSImageView(frame: effect.bounds.insetBy(dx: 5, dy: 7))
        icon.image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: "Move")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        icon.autoresizingMask = [.width, .height]
        effect.addSubview(icon)

        grip = GripView(frame: effect.bounds)
        grip.autoresizingMask = [.width, .height]
        grip.target = target
        grip.onDragEnded = onMoved
        grip.toolTip = "Drag to move"
        effect.addSubview(grip)
        tab.contentView = effect
    }

    var isShown: Bool { tab.parent != nil }

    /// Shows the tab next to the panel (call after the panel is on screen) or hides it.
    func setShown(_ shown: Bool) {
        guard let target else { return }
        if shown {
            tab.level = target.level
            position()
            if tab.parent == nil { target.addChildWindow(tab, ordered: .above) }
            tab.orderFrontRegardless()
        } else if tab.parent != nil {
            target.removeChildWindow(tab)
            tab.orderOut(nil)
        }
    }

    /// Re-aligns the tab after the panel changed size (it follows moves by itself).
    func position() {
        guard let target else { return }
        let frame = target.frame
        let y = alignment == .top ? frame.maxY - Self.size.height - 8 : frame.midY - Self.size.height / 2
        tab.setFrameOrigin(NSPoint(x: frame.minX - Self.size.width - 4, y: y.rounded()))
    }
}

/// Dragging the view moves its window (for panel headers, like a title bar). Buttons and menus in
/// it keep working; a drag that starts on empty space or text moves the window.
private struct WindowDragModifier: ViewModifier {
    var onEnded: () -> Void

    private final class Drag {
        weak var window: NSWindow?
        var mouse: NSPoint = .zero
        var origin: NSPoint = .zero
    }

    @State private var drag: Drag?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in
                        let mouse = NSEvent.mouseLocation
                        if drag == nil {
                            let number = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
                            guard let window = NSApp.window(withWindowNumber: number) else { return }
                            let start = Drag()
                            start.window = window
                            start.mouse = mouse
                            start.origin = window.frame.origin
                            drag = start
                        }
                        guard let drag, let window = drag.window else { return }
                        window.setFrameOrigin(NSPoint(x: drag.origin.x + mouse.x - drag.mouse.x,
                                                      y: drag.origin.y + mouse.y - drag.mouse.y))
                    }
                    .onEnded { _ in
                        if drag != nil { onEnded() }
                        drag = nil
                    })
    }
}

extension View {
    /// Makes this view (a panel's header) drag its window. `onEnded` runs when a drag finishes.
    func dragsWindow(onEnded: @escaping () -> Void = {}) -> some View {
        modifier(WindowDragModifier(onEnded: onEnded))
    }
}
