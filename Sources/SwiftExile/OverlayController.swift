import AppKit
import SwiftExileCore

/// Borderless, transparent, non-activating panel above the game (plan §2.1).
final class OverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver // parity with setAlwaysOnTop(true, 'screen-saver')
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    // Non-activating panels can take keyboard focus without activating the app, so the game
    // stays frontmost and a fullscreen game Space is never left.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Connects the window tracker, the overlay focus model, the panel, and the renderer events.
@MainActor
final class OverlayController {
    let panel = OverlayPanel()
    private let webHost: WebViewHost
    private let tracker: GameWindowTracker
    private let hub: EventHub
    private let status: HostStatus
    private var model = OverlayFocusModel()
    private var overlayKey = HostConfig.default.overlayKey
    private var keyMonitor: Any?
    private var tokens: [NSObjectProtocol] = []
    private(set) var wasUsedRecently = true

    init(webHost: WebViewHost, tracker: GameWindowTracker, hub: EventHub, status: HostStatus) {
        self.webHost = webHost
        self.tracker = tracker
        self.hub = hub
        self.status = status
        panel.contentView = webHost.webView

        tracker.onAttach = { [weak self] snapshot in self?.gameAttached(snapshot) }
        tracker.onDetach = { [weak self] in self?.gameDetached() }
        tracker.onGeometryChange = { [weak self] snapshot in self?.place(snapshot) }
        tracker.onFocusChange = { [weak self] _ in self?.scheduleFocusUpdate() }

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] note in
                let label = note.name == NSWindow.didBecomeKeyNotification ? "panel became key" : "panel resigned key"
                MainActor.assumeIsolated {
                    self?.trace(label)
                    self?.scheduleFocusUpdate()
                }
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let label = note.name == NSApplication.didBecomeActiveNotification ? "app became active" : "app resigned active"
                MainActor.assumeIsolated { self?.trace(label) }
            })
        }
        // Escape, Ctrl+W, and the overlay key while the overlay has focus (OverlayWindow.ts:134-168).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let isPanelEvent = event.window === self?.panel
            let swallow = MainActor.assumeIsolated {
                self?.handleKeyDown(keyCode: keyCode, flags: flags, isPanelEvent: isPanelEvent) ?? false
            }
            return swallow ? nil : event
        }
    }

    // MARK: Inputs

    func toggle(source: String = "menu") {
        trace("toggle from \(source)")
        apply(model.toggle())
    }

    func focusGame(source: String = "renderer") {
        trace("focus-game from \(source)")
        apply(model.assertGameActive())
    }

    /// `assertOverlayActive`, for the copy-item flow and the widget area tracker.
    func activate(source: String) {
        trace("activate from \(source)")
        apply(model.assertOverlayActive())
    }

    /// Upstream `GameWindow.isActive`: hotkeys are registered only while this is true.
    var isGameActive: Bool { model.gameActive }
    var isInteractable: Bool { model.isInteractable }
    var onGameAttached: (() -> Void)?
    func renderState(shouldShow: Bool) { apply(model.renderState(shouldShow: shouldShow)) }
    func usedRecently(isOverlay: Bool) { wasUsedRecently = isOverlay }

    func hostConfigChanged(_ config: HostConfig) {
        overlayKey = config.overlayKey
        tracker.windowTitle = config.windowTitle
        apply(model.setHideOverlayOnBlur(config.hideOverlayOnBlur))
        // The renderer sends its host config on every (re)load; replay the current state so a
        // reloaded page leaves its loading screen without waiting for the next focus change.
        if model.isAttached {
            send(IpcMessage(.overlayAttached))
            sendFocusChange(game: model.gameActive, overlay: model.isInteractable, usingHotkey: false)
        }
    }

    private func gameAttached(_ snapshot: GameWindowTracker.Snapshot) {
        place(snapshot)
        status.attached(snapshot)
        onGameAttached?()
        apply(model.attached())
        scheduleFocusUpdate()
    }

    private func gameDetached() {
        status.detached()
        apply(model.detached())
    }

    private func place(_ snapshot: GameWindowTracker.Snapshot) {
        panel.setFrame(snapshot.contentRect, display: true)
        status.gameRect = snapshot.contentRect
    }

    /// Deferred so panel key changes caused while applying effects don't re-enter `apply`.
    private func scheduleFocusUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let effects = self.model.focusChanged(gameFrontmost: self.tracker.gameFrontmost, overlayIsKey: self.panel.isKeyWindow)
            if !effects.isEmpty {
                self.trace("focus update gameFrontmost=\(self.tracker.gameFrontmost) panelKey=\(self.panel.isKeyWindow) → \(effects)")
            }
            self.apply(effects)
        }
    }

    // MARK: Retaking focus (risk R6)

    /// Under Wine in windowed fullscreen the game grabs keyboard focus about once a second while the
    /// overlay is interactable. Take it back each time, at most once per `retakeInterval`; a grab
    /// inside the interval is retried when it ends, so none is missed.
    private static let retakeInterval: TimeInterval = 0.15
    private var lastRetake = Date.distantPast
    private var pendingRetake: DispatchWorkItem?
    private var retakesThisSession = 0

    private func retakeFocus() {
        let wait = Self.retakeInterval - Date().timeIntervalSince(lastRetake)
        guard wait <= 0 else {
            guard pendingRetake == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.pendingRetake = nil
                self?.retakeFocusIfStillNeeded()
            }
            pendingRetake = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            return
        }
        lastRetake = Date()
        retakesThisSession += 1
        trace("game took keyboard focus; retaking (\(retakesThisSession) this session)")
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webHost.webView)
    }

    private func retakeFocusIfStillNeeded() {
        guard model.isInteractable, !panel.isKeyWindow, tracker.gameFrontmost else { return }
        retakeFocus()
    }

    /// `SWIFTEXILE_ACTIVATION=app` activates SwiftExile on every interactable switch (diagnostics).
    private let alwaysActivate = ProcessInfo.processInfo.environment["SWIFTEXILE_ACTIVATION"] == "app"

    /// Focus tracing for development (`SWIFTEXILE_TRACE_FOCUS=1`).
    private let traceFocus = ProcessInfo.processInfo.environment["SWIFTEXILE_TRACE_FOCUS"] == "1"
    private func trace(_ message: @autoclosure () -> String) {
        guard traceFocus else { return }
        let line = "debug [Focus] \(message()) (appActive=\(NSApp.isActive), frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))"
        let hub = hub
        Task { await hub.log(line) }
    }

    /// Returns true when the key press was handled and must not reach the web view.
    private func handleKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags, isPanelEvent: Bool) -> Bool {
        guard isPanelEvent || panel.isKeyWindow else { return false }
        guard let hotkey = KeyNames.hotkeyString(
            macKeyCode: keyCode,
            ctrl: flags.contains(.control), shift: flags.contains(.shift), alt: flags.contains(.option)
        ) else { return false }

        if hotkey == "Escape" || hotkey == "Ctrl + W" {
            DispatchQueue.main.async { [weak self] in self?.focusGame(source: "key \(hotkey)") }
            return true
        }
        if hotkey == overlayKey {
            DispatchQueue.main.async { [weak self] in self?.toggle(source: "overlay key") }
            return true
        }
        return false
    }

    // MARK: Effects

    private func apply(_ effects: [OverlayFocusModel.Effect]) {
        if !effects.isEmpty { trace("apply \(effects)") }
        for effect in effects {
            switch effect {
            case .broadcastOverlayAttached:
                send(IpcMessage(.overlayAttached))
            case .broadcastFocusChange(let game, let overlay, let usingHotkey):
                sendFocusChange(game: game, overlay: overlay, usingHotkey: usingHotkey)
            case .setInteractable(true):
                retakesThisSession = 0
                panel.ignoresMouseEvents = false
                if alwaysActivate { NSApp.activate() }
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(webHost.webView)
            case .setInteractable(false):
                pendingRetake?.cancel()
                pendingRetake = nil
                if retakesThisSession > 0 {
                    let count = retakesThisSession
                    let hub = hub
                    Task { await hub.log("debug [Overlay] the game grabbed keyboard focus \(count) time(s) while the overlay was interactive") }
                }
                panel.ignoresMouseEvents = true
                if panel.isKeyWindow {
                    // Ordering out the key panel hands keyboard focus back to the frontmost app.
                    panel.orderOut(nil)
                    if model.isVisible { panel.orderFrontRegardless() }
                }
            case .focusGame:
                if let pid = tracker.current?.pid, let game = NSRunningApplication(processIdentifier: pid) {
                    // Cooperative activation (macOS 14): yield to the game, then ask it to activate.
                    NSApp.yieldActivation(to: game)
                    game.activate(from: .current, options: [])
                }
            case .retakeFocus:
                retakeFocus()
            case .show:
                panel.orderFrontRegardless()
            case .hide:
                panel.orderOut(nil)
            }
        }
        status.gameFocused = model.gameActive
        status.overlayInteractable = model.isInteractable
        status.overlayVisible = model.isVisible
    }

    private func sendFocusChange(game: Bool, overlay: Bool, usingHotkey: Bool) {
        if let message = try? IpcMessage(.focusChange, FocusChangePayload(game: game, overlay: overlay, usingHotkey: usingHotkey)) {
            send(message)
        }
    }

    private func send(_ message: IpcMessage) {
        let hub = hub
        Task { await hub.send(.broadcast, message) }
    }
}
