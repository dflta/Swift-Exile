import AppKit
import SwiftExileCore
import SwiftUI

/// Borderless, non-activating panel for the native price check.
final class PriceCheckPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .screenSaver // after isFloatingPanel, which resets the level; above the game (layer 26)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows the native SwiftUI price check next to the game's stash or inventory panel.
@MainActor
final class NativePriceCheckController {
    static let maxSize = CGSize(width: 440, height: 860)

    let model: PriceCheckModel
    private let panel = PriceCheckPanel()
    private var hosting: NSHostingController<PriceCheckView>!
    private var keyMonitor: Any?
    private var resizeObserver: NSObjectProtocol?
    /// Top-left corner (Cocoa) to keep while SwiftUI resizes the panel.
    private var anchorTop: CGPoint?
    /// Where the panel can be at most (Quartz), for the mouse-away tracker.
    private(set) var areaRect: CGRect = .zero

    init(model: PriceCheckModel) {
        self.model = model
        let hosting = NSHostingController(rootView: PriceCheckView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        self.hosting = hosting
        hosting.rootView = PriceCheckView(model: model, onClose: { [weak self] in self?.hide() })
        panel.contentViewController = hosting

        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepAnchored() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53 || (event.keyCode == 13 && event.modifierFlags.contains(.control))
            let isOurs = MainActor.assumeIsolated { event.window === self?.panel }
            guard isEscape, isOurs else { return event }
            MainActor.assumeIsolated { self?.hide() }
            return nil
        }
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }

    /// Renders the panel's content to a PNG (development checks; no screen recording needed).
    func snapshot(to url: URL) -> Bool {
        guard let view = panel.contentView, view.bounds.width > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// - Parameters:
    ///   - cursor: where the item was, Quartz coordinates.
    ///   - game: the game's drawable area, Quartz coordinates.
    ///   - focus: take keyboard focus (locked price check).
    func show(clipboard: String, cursor: CGPoint, game: CGRect, focus: Bool) {
        let frame = PriceCheckPlacement.frame(game: game, cursorX: cursor.x, size: Self.maxSize)
        areaRect = frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = ScreenCoordinates.cocoaRect(fromQuartz: frame, primaryHeight: primaryHeight)
        anchorTop = CGPoint(x: cocoa.minX, y: cocoa.maxY)
        panel.setFrameTopLeftPoint(anchorTop!)
        panel.orderFrontRegardless()
        if focus { panel.makeKey() }
        Task { await model.show(clipboard: clipboard, advanced: focus) }
    }

    func activate() {
        guard panel.isVisible else { return }
        panel.makeKey()
    }

    /// Hands keyboard focus back to the game, so keys SwiftExile synthesizes next (e.g. the copy
    /// chord) reach the game instead of this panel. The panel stays visible.
    func releaseFocus(toGame pid: pid_t?) {
        guard panel.isKeyWindow || NSApp.isActive else { return }
        // Deactivate instead of ordering the panel out and back in: that made AppKit pass key focus
        // to SwiftExile's overlay panel, so the copy chord went there instead of to the game.
        NSApp.deactivate()
        if let pid, let game = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: game)
            game.activate(from: .current, options: [])
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func keepAnchored() {
        guard let anchorTop, panel.frame.origin.y + panel.frame.height != anchorTop.y else { return }
        panel.setFrameTopLeftPoint(anchorTop)
    }
}
