import AppKit
import SwiftExileCore

/// Port of `main/src/shortcuts/Shortcuts.ts` plus `WidgetAreaTracker.ts` and
/// `OverlayVisibility.ts`, on top of `InputTap`.
@MainActor
final class ShortcutController {
    private let hub: EventHub
    private let overlay: OverlayController
    private let status: HostStatus
    private let tap: InputTap
    private let synthesizer = KeySynthesizer()
    private let poller = ItemClipboardPoller(pasteboard: SystemPasteboard())

    private var rawActions: [ShortcutAction] = []
    private var active: [Hotkey: ShortcutAction] = [:]
    private var swallowedKeyUps: Set<UInt16> = []
    private var showModsKey = "Alt"
    private var gameConfigOverride: String?
    private var logKeys = false
    private var areaModel = WidgetAreaModel()
    private var altModel = AltVisibilityModel()
    private var altHideWork: DispatchWorkItem?
    private var permissionTimer: Timer?
    /// Native SwiftUI price check (preview). When enabled, price-check items go there instead of
    /// to Exiled Exchange 2's web widget.
    var nativePriceCheck: NativePriceCheckController?
    static let nativePriceCheckDefaultsKey = "nativePriceCheck"
    private enum AreaTarget { case renderer, native }
    private var areaTarget: AreaTarget = .renderer

    init(hub: EventHub, overlay: OverlayController, status: HostStatus) {
        self.hub = hub
        self.overlay = overlay
        self.status = status
        self.tap = InputTap(log: { line in Task { await hub.log(line) } })
        tap.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        tap.onPointer = { [weak self] event in self?.handlePointer(event) }
    }

    // MARK: Lifecycle

    func start() {
        if tap.start() {
            status.hotkeysAvailable = true
            log("info [Shortcuts] global hotkeys active")
            return
        }
        status.hotkeysAvailable = false
        log("warn [Shortcuts] could not create the keyboard tap; asking for Input Monitoring permission")
        _ = CGRequestListenEventAccess()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tap.start() else { return }
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.status.hotkeysAvailable = true
                self.log("info [Shortcuts] global hotkeys active")
            }
        }
    }

    func hostConfigChanged(_ config: HostConfig) {
        rawActions = config.shortcuts.compactMap(ShortcutAction.init(json:))
        logKeys = config.logKeys
        gameConfigOverride = config.gameConfig
        let poller = poller
        Task { await poller.configure(restoreClipboard: config.restoreClipboard, initialDelayMs: config.initialDelay) }
        reloadShowModsKey()
        rebuild()
    }

    func gameAttached() {
        reloadShowModsKey()
        rebuild()
    }

    func trackArea(_ payload: TrackAreaPayload) {
        areaTarget = .renderer
        areaModel.start(WidgetAreaModel.Area(
            holdKey: payload.holdKey,
            closeThreshold: payload.closeThreshold,
            from: CGPoint(x: payload.from.x, y: payload.from.y),
            rect: CGRect(x: payload.area.x, y: payload.area.y, width: payload.area.width, height: payload.area.height)
        ))
    }

    /// Reads the show-mods key from the game's settings (`GameConfig.ts`): user path first,
    /// then the path derived from the running game.
    private func reloadShowModsKey() {
        let path = (gameConfigOverride?.isEmpty == false ? gameConfigOverride : nil) ?? status.derivedConfigPath
        let contents = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let result = GameConfigReader.showModsKey(iniContents: contents)
        if result.key != showModsKey || path != nil {
            log("info [GameConfig] show advanced item descriptions: \(result.key)\(result.fromFile ? "" : " (default; game settings not found)")")
        }
        showModsKey = result.key
    }

    private func rebuild() {
        let result = ShortcutRegistry.build(actions: rawActions, showModsKey: showModsKey)
        result.errors.forEach(log)
        var map: [Hotkey: ShortcutAction] = [:]
        for action in result.active where action.action != .testOnly {
            guard let hotkey = Hotkey(action.shortcut), hotkey.macKeyCode != nil else {
                log("warn [Shortcuts] cannot register \"\(action.shortcut)\" on macOS")
                continue
            }
            map[hotkey] = action
        }
        active = map
        status.registeredHotkeys = map.keys.map(\.string).sorted()
    }

    // MARK: Keyboard

    private func handleKey(_ event: InputTap.KeyEvent) -> Bool {
        switch event.kind {
        case .flagsChanged:
            let isOption = event.keyCode == 58 || event.keyCode == 61
            if isOption && event.alt && !event.ctrl && !event.shift && !event.command {
                applyAlt(altModel.altPressedAlone(overlayInteractable: overlay.isInteractable))
            } else if !event.alt {
                applyAlt(altModel.otherInput())
            }
            return false

        case .up:
            if !event.alt { applyAlt(altModel.otherInput()) }
            if logKeys { log("debug [Shortcuts] Keyup \(KeyNames.byMacKeyCode[event.keyCode] ?? "not_supported_key")") }
            return swallowedKeyUps.remove(event.keyCode) != nil

        case .down:
            applyAlt(altModel.otherInput())
            guard let name = KeyNames.byMacKeyCode[event.keyCode] else { return false }
            let hotkey = Hotkey(key: name, ctrl: event.ctrl, shift: event.shift, alt: event.alt)
            if logKeys { log("debug [Shortcuts] Keydown \(hotkey.string)") }
            // Hotkeys are registered only while the game is active (Shortcuts.ts:61-71), and also
            // while the native price check has focus: it's our panel, with the game right behind it,
            // so the next item can be checked without closing it first.
            let nativeFocused = nativePriceCheck?.isKey ?? false
            guard overlay.isGameActive || nativeFocused, !event.command, let action = active[hotkey] else { return false }
            swallowedKeyUps.insert(event.keyCode)
            if !event.isRepeat {
                if nativeFocused {
                    // Give focus back to the game first, so the copy chord reaches it, not the panel.
                    nativePriceCheck?.releaseFocus(toGame: status.gamePid)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in self?.run(action) }
                } else {
                    DispatchQueue.main.async { [weak self] in self?.run(action) }
                }
            }
            return true
        }
    }

    private func run(_ entry: ShortcutAction) {
        if logKeys { log("debug [Shortcuts] Action type: \(entry.action)") }
        let held = KeySequences.heldModifiers(after: entry.shortcut, keepModKeys: entry.keepModKeys)
        synthesizer.post(KeySequences.releaseAfterHotkey(entry.shortcut, keepModKeys: entry.keepModKeys), alsoHeld: held)

        switch entry.action {
        case .toggleOverlay:
            areaModel.stop()
            overlay.toggle(source: "hotkey")
        case .copyItem(let target, let focusOverlay):
            copyItem(target: target, focusOverlay: focusOverlay, held: held)
        case .triggerEvent(let target):
            send(.broadcast, try? IpcMessage(.widgetAction, WidgetActionPayload(target: target)))
        case .stashSearch, .pasteInChat, .ocrText:
            log("warn [Shortcuts] \"\(entry.shortcut)\": this action is not implemented on macOS yet")
        case .testOnly, .unknown:
            break
        }
    }

    /// Copy-item flow (`Shortcuts.ts:215-244`).
    private func copyItem(target: String, focusOverlay: Bool, held: Set<String>) {
        let position = CGEvent(source: nil)?.location ?? .zero
        let modifiers = KeySequences.copyItemModifiersToPress(
            showModsKey: showModsKey, heldModifiers: held,
            retoggleHeld: ProcessInfo.processInfo.environment["SWIFTEXILE_RETOGGLE"].map { $0 == "1" } ?? status.gameFlavor.retogglesHeldModifiers)
        let poller = poller
        let startedAt = Date()
        Task { [weak self] in
            do {
                let text = try await poller.readItemText(afterPrepare: { [weak self] in
                    await MainActor.run { self?.pressCopyKeys(modifiers, held: held) }
                })
                self?.deliverItem(text: text, target: target, position: position, focusOverlay: focusOverlay,
                                  holdKey: held.first(where: { $0 == "Ctrl" || $0 == "Alt" }), startedAt: startedAt)
            } catch {
                self?.log("warn [ClipboardPoller] No item text found.")
            }
        }
    }

    /// `pressKeysToCopyItemText` (`Shortcuts.ts:293-324`): modifiers down, tap C, release 10 ms later.
    private func pressCopyKeys(_ modifiers: [String], held: Set<String>) {
        synthesizer.post(modifiers.map { KeyStep($0, down: true) }, alsoHeld: held)
        synthesizer.tap("C", alsoHeld: held)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.synthesizer.post(modifiers.reversed().map { KeyStep($0, down: false) }, alsoHeld: held)
        }
    }

    private func deliverItem(text: String, target: String, position: CGPoint, focusOverlay: Bool, holdKey: String?, startedAt: Date) {
        areaModel.stop()
        let advanced = text.contains("{ ") ? "with advanced mod descriptions" : "without advanced mod descriptions"
        log("debug [Shortcuts] item copied in \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms → \(target), \(advanced)")
        if target == "price-check", showNativePriceCheck(text: text, position: position, focus: focusOverlay, holdKey: holdKey) {
            return
        }
        send(.lastActive, try? IpcMessage(.itemText, ItemTextPayload(
            target: target, clipboard: text, x: position.x, y: position.y, focusOverlay: focusOverlay)))
        if focusOverlay && overlay.wasUsedRecently {
            overlay.activate(source: "copy-item")
        }
    }

    /// Sends the item to the native price check if it's enabled. Returns false to fall back to the renderer.
    @discardableResult
    /// - Parameter fallbackArea: Cocoa rect to use when no game window is attached (debug runs).
    func showNativePriceCheck(text: String, position: CGPoint, focus: Bool, holdKey: String?, fallbackArea: CGRect? = nil) -> Bool {
        guard let native = nativePriceCheck,
              UserDefaults.standard.bool(forKey: Self.nativePriceCheckDefaultsKey),
              let gameCocoa = status.gameRect ?? fallbackArea
        else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let game = ScreenCoordinates.cocoaRect(fromQuartz: gameCocoa, primaryHeight: primaryHeight) // involution: Cocoa → Quartz
        native.show(clipboard: text, cursor: position, game: game, focus: focus)
        if !focus {
            // Same behavior as upstream's track-area for the web widget (PriceCheckWindow.vue:265-288).
            areaTarget = .native
            areaModel.start(WidgetAreaModel.Area(holdKey: holdKey ?? "", closeThreshold: 40, from: position, rect: native.areaRect))
        }
        return true
    }

    // MARK: Pointer

    private func handlePointer(_ event: InputTap.PointerEvent) {
        if event.kind == .moved && !event.alt {
            applyAlt(altModel.otherInput())
        }
        guard areaModel.isTracking else { return }
        let effects: [WidgetAreaModel.Effect]
        let interactable = areaTarget == .native ? (nativePriceCheck?.isKey ?? false) : overlay.isInteractable
        switch event.kind {
        case .moved:
            effects = areaModel.mouseMoved(to: event.location, ctrl: event.ctrl, alt: event.alt, overlayInteractable: interactable)
        case .down:
            effects = areaModel.mouseDown(at: event.location)
        }
        if areaTarget == .native, let native = nativePriceCheck {
            for effect in effects {
                switch effect {
                case .hideExclusiveWidget, .focusGame: native.hide()
                case .activateOverlay: native.activate()
                }
            }
            return
        }
        for effect in effects {
            switch effect {
            case .hideExclusiveWidget:
                send(.broadcast, IpcMessage(.hideExclusiveWidget))
            case .activateOverlay:
                overlay.activate(source: "area tracker")
            case .focusGame:
                overlay.focusGame(source: "area tracker")
            }
        }
    }

    // MARK: Alt-hold visibility

    private func applyAlt(_ effects: [AltVisibilityModel.Effect]) {
        for effect in effects {
            switch effect {
            case .scheduleHide(let milliseconds):
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.applyAlt(self.altModel.hideTimerFired())
                }
                altHideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: work)
            case .cancelHide:
                altHideWork?.cancel()
                altHideWork = nil
            case .broadcastVisible(let visible):
                send(.broadcast, try? IpcMessage(.visibility, VisibilityPayload(isVisible: visible)))
            }
        }
    }

    // MARK: Helpers

    private func send(_ target: EventHub.Target, _ message: IpcMessage?) {
        guard let message else { return }
        let hub = hub
        Task { await hub.send(target, message) }
    }

    private func log(_ line: String) {
        let hub = hub
        Task { await hub.log(line) }
    }
}
