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
    private var activationObserver: NSObjectProtocol?
    /// Pinned panel hidden because another app came to the front; shown again with the game.
    private var suspended = false
    /// Whether a process is the game (set by the app delegate).
    var isGame: (pid_t) -> Bool = { _ in false }
    /// SwiftExile's own overlay window, which covers the game and must not count as "inside".
    var overlayWindowNumber: () -> Int = { 0 }
    /// Top-left corner (Cocoa) to keep while SwiftUI resizes the panel.
    private var anchorTop: CGPoint?
    /// Where the panel can be at most (Quartz), for the mouse-away tracker.
    private(set) var areaRect: CGRect = .zero

    init(model: PriceCheckModel) {
        self.model = model
        let hosting = NSHostingController(rootView: PriceCheckView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        self.hosting = hosting
        hosting.rootView = PriceCheckView(model: model, onClose: { [weak self] in self?.hide() },
                                          onMoved: { [weak self] in self?.movedByUser() })
        panel.contentViewController = hosting

        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepAnchored() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.applicationActivated(pid) }
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
    var isPinned: Bool { model.isPinned }
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
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = ScreenCoordinates.cocoaRect(fromQuartz: frame, primaryHeight: primaryHeight)
        anchorTop = CGPoint(x: cocoa.minX, y: cocoa.maxY)
        updateArea()
        suspended = false
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
        suspended = false
        model.isPinned = false
    }

    /// A mouse click anywhere (from the event tap, Quartz coordinates). Clicking outside the panel
    /// closes it unless it's pinned, like upstream's price check when the overlay loses focus.
    func mouseDown(atQuartz point: CGPoint) {
        guard panel.isVisible, !model.isPinned else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = CGPoint(x: point.x, y: primaryHeight - point.y)
        if panel.frame.contains(cocoa) || isOwnPopup(at: cocoa) { return }
        hide()
    }

    /// Menus and popovers opened from the panel are separate windows of this process.
    private func isOwnPopup(at cocoa: CGPoint) -> Bool {
        let number = NSWindow.windowNumber(at: cocoa, belowWindowWithWindowNumber: 0)
        guard number > 0, number != overlayWindowNumber(),
              let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
              let owner = info.first?[kCGWindowOwnerPID as String] as? pid_t
        else { return false }
        return owner == getpid()
    }

    /// Another app in front: close (or, when pinned, hide until the game is back).
    private func applicationActivated(_ pid: pid_t) {
        guard pid != getpid() else { return }
        if isGame(pid) {
            if suspended {
                suspended = false
                panel.orderFrontRegardless()
            }
            return
        }
        guard panel.isVisible else { return }
        // Pinned, or "restore the overlay when you return" on: hide until the game is back.
        if model.isPinned || UserDefaults.standard.bool(forKey: OverlayController.restoreOnReturnKey) {
            suspended = true
            panel.orderOut(nil)
        } else {
            hide()
        }
    }

    /// Dragged by its header: keep the new place while SwiftUI resizes it.
    private func movedByUser() {
        anchorTop = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        updateArea()
    }

    /// The most the panel can cover, in Quartz coordinates.
    private func updateArea() {
        guard let anchorTop else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = CGRect(x: anchorTop.x, y: anchorTop.y - Self.maxSize.height,
                           width: Self.maxSize.width, height: Self.maxSize.height)
        areaRect = CGRect(x: cocoa.minX, y: primaryHeight - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }

    private func keepAnchored() {
        guard let anchorTop, panel.frame.origin.y + panel.frame.height != anchorTop.y else { return }
        panel.setFrameTopLeftPoint(anchorTop)
    }
}
