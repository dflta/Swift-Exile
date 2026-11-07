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
    private var stashScroll = false
    private var restoreClipboard = false
    /// A chat or stash-search macro is running (upstream's `restoreShortly` throttle).
    private var textBoxBusy = false
    private var lastStashScroll = Date.distantPast
    private var areaModel = WidgetAreaModel()
    private var altModel = AltVisibilityModel()
    private var altHideWork: DispatchWorkItem?
    private var permissionTimer: Timer?
    /// Native SwiftUI price check (preview). When enabled, price-check items go there instead of
    /// to Exiled Exchange 2's web widget.
    var nativePriceCheck: NativePriceCheckController?
    var itemCheck: ItemCheckController?
    /// When the game last put item text on the clipboard, and the pasteboard's change count then.
    private var lastGameCopy: (at: Date, changeCount: Int)?
    static let nativeItemCheckDefaultsKey = "nativeItemCheck"
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
        stashScroll = config.stashScroll
        restoreClipboard = config.restoreClipboard
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
            let nativeFocused = (nativePriceCheck?.isKey ?? false) || (itemCheck?.isKey ?? false)
            guard overlay.isGameActive || nativeFocused || overlay.companionHasFocus, !event.command,
                  let action = active[hotkey] else { return false }
            // While SwiftExile's settings (or the bar's field) have focus inside the open overlay, only
            // the overlay key works, to close the overlay as it does from the web overlay.
            if !overlay.isGameActive && !nativeFocused {
                guard action.action == .toggleOverlay, overlay.isInteractable, !HotkeyField.isRecordingAny else { return false }
            }
            swallowedKeyUps.insert(event.keyCode)
            if !event.isRepeat {
                if nativeFocused {
                    // Give focus back to the game first, so the copy chord reaches it, not the panel.
                    nativePriceCheck?.releaseFocus(toGame: status.gamePid)
                    itemCheck?.releaseFocus(toGame: status.gamePid)
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
        case .pasteInChat(let text, let send):
            runTextBox(TextBox.typeInChat(text, send: send, command: status.gameFlavor.commandModifier), held: held)
        case .stashSearch(let text):
            runTextBox(TextBox.stashSearch(text, command: status.gameFlavor.commandModifier), held: held,
                       typed: TextBox.stashSearchTyped(text))
        case .ocrText:
            // Upstream only runs heist-gem OCR on Windows (Shortcuts.ts:249).
            log("warn [Shortcuts] \"\(entry.shortcut)\": OCR is not implemented on macOS yet")
        case .testOnly, .unknown:
            break
        }
    }

    // MARK: Chat and stash search

    /// Stash search requested from the overlay (`CLIENT->MAIN::user-action`, Shortcuts.ts:73-77):
    /// the game gets focus back first (`overlay.assertGameActive()`).
    func stashSearchFromOverlay(_ text: String) {
        overlay.focusGame(source: "stash-search")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.runTextBox(TextBox.stashSearch(text, command: self.status.gameFlavor.commandModifier), held: [],
                            typed: TextBox.stashSearchTyped(text))
        }
    }

    /// `restoreShortly` (HostClipboard.ts:87-103) around a chat or stash-search macro: ignored while
    /// one is typing (protects against "Too many actions"); the clipboard is restored afterwards
    /// when the "restore clipboard" setting is on.
    ///
    /// Under Wine, for about 2 s after the game copies an item, pasting still pastes that item: Wine
    /// takes a Mac clipboard change into the game's clipboard only on its 2 s check
    /// (`CLIPBOARD_UPDATE_DELAY` in winemac.drv's clipboard.c). Writing the clipboard while Wine still
    /// owned it (which should be noticed at once) didn't help in game. So a stash search right after a
    /// copy is typed key by key instead (`typed`), when the keyboard layout can type it; otherwise
    /// the macro waits out the rest of those 2 s (`wineClipboardWaitMs`, 2100). A newer macro, or
    /// another item copy, replaces one that is still waiting.
    private func runTextBox(_ steps: [TextBoxStep], held: Set<String>, typed: [TextBoxStep]? = nil) {
        var steps = steps
        var saved = NSPasteboard.general.string(forType: .string)
        if let carried = carriedClipboard, Date().timeIntervalSince(carried.at) < 5 {
            saved = carried.text // what the user had before a macro that was replaced
        }
        carriedClipboard = nil
        if textBoxBusy {
            guard let waiting = waitingMacro else {
                log("debug [Shortcuts] chat/stash macro ignored: the previous one is still typing")
                return
            }
            waiting.task.cancel()
            saved = waiting.saved
            waitingMacro = nil
            log("debug [Shortcuts] chat/stash macro replaced one that was still waiting")
        }
        textBoxBusy = true
        // What gets pasted, for when the game refuses a chat message.
        let texts = steps.compactMap { if case .setClipboard(let text) = $0 { return text } else { return nil } }
        log("debug [Shortcuts] chat/stash macro: \(texts.map { "\"\($0)\"" }.joined(separator: ", ")); game in front: \(overlay.isGameActive)")
        let pasteboard = NSPasteboard.general
        var wait = Duration.zero
        var typedKeys: [String: [KeyboardLayoutMap.Key]] = [:]
        let waitMs = UserDefaults.standard.object(forKey: Self.wineClipboardWaitKey) as? Int ?? 2100
        let sinceCopyMs = lastGameCopy.map { Int(Date().timeIntervalSince($0.at) * 1000) } ?? Int.max
        if status.gameFlavor.isWine, sinceCopyMs < waitMs {
            let layout = KeyboardLayoutMap.current()
            let texts = (typed ?? []).compactMap { if case .typeText(let text) = $0 { return text } else { return nil } }
            if let typed, let layout, !texts.isEmpty,
               texts.allSatisfy({ layout.keys(for: $0) != nil }) {
                steps = typed
                for text in texts { typedKeys[text] = layout.keys(for: text) }
                log("debug [Shortcuts] typing the search (the game copied an item \(sinceCopyMs) ms ago, so Wine would still paste it)")
            } else {
                wait = .milliseconds(waitMs - sinceCopyMs)
                log("debug [Shortcuts] waiting \(waitMs - sinceCopyMs) ms for Wine to see the new clipboard (the game copied an item \(sinceCopyMs) ms ago)")
            }
        }
        let delay = TextBox.restoreDelay(isWine: status.gameFlavor.isWine)
        let restore = restoreClipboard
        let synthesizer = synthesizer
        let task = Task { @MainActor [weak self] in
            var started = false
            for step in steps {
                switch step {
                case .setClipboard(let text):
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                case .tap(let key, let modifiers):
                    if !started {
                        if wait > .zero {
                            do { try await Task.sleep(for: wait) } catch { return } // replaced: the newer one restores
                        }
                        self?.waitingMacro = nil
                        started = true
                        // Keys must reach the game, not a SwiftExile panel that just closed or has focus.
                        await self?.focusGameForTyping()
                    }
                    synthesizer.tap(key, modifiers: modifiers, alsoHeld: held)
                case .typeText(let text):
                    if !started {
                        started = true
                        self?.waitingMacro = nil
                        await self?.focusGameForTyping()
                    }
                    try? await Task.sleep(for: .milliseconds(40)) // the search box opens after Ctrl+F
                    // All at once: the stash filters as it's typed, so typing slowly shows every step.
                    for key in typedKeys[text] ?? [] { synthesizer.type(key) }
                }
            }
            try? await Task.sleep(for: delay)
            if restore, let saved {
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
            self?.textBoxBusy = false
        }
        if wait > .zero { waitingMacro = (task, saved) }
    }

    /// A macro still waiting for Wine's clipboard check, and the clipboard to restore after it.
    private var waitingMacro: (task: Task<Void, Never>, saved: String?)?
    /// The clipboard from before a cancelled macro, for the next one to restore.
    private var carriedClipboard: (text: String?, at: Date)?
    static let wineClipboardWaitKey = "wineClipboardWaitMs"

    /// Another item was copied while a macro waits: the game's clipboard changed again, so that macro
    /// would paste the item. Drop it (a new search follows if the copy was for one).
    private func cancelWaitingMacro() {
        guard let waiting = waitingMacro else { return }
        waiting.task.cancel()
        waitingMacro = nil
        textBoxBusy = false
        carriedClipboard = (waiting.saved, Date())
        log("debug [Shortcuts] chat/stash macro dropped: another item was copied while it waited")
    }

    /// Gives keyboard focus back to the game if a SwiftExile window has it.
    private func focusGameForTyping() async {
        guard NSApp.keyWindow != nil || NSApp.isActive else { return }
        NSApp.deactivate()
        if let pid = status.gamePid, let game = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: game)
            game.activate(from: .current, options: [])
        }
        try? await Task.sleep(for: .milliseconds(80))
    }

    /// Copy-item flow (`Shortcuts.ts:215-244`).
    private func copyItem(target: String, focusOverlay: Bool, held: Set<String>) {
        cancelWaitingMacro()
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
        lastGameCopy = (Date(), NSPasteboard.general.changeCount)
        let advanced = text.contains("{ ") ? "with advanced mod descriptions" : "without advanced mod descriptions"
        log("debug [Shortcuts] item copied in \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms → \(target), \(advanced)")
        if target == "price-check", showNativePriceCheck(text: text, position: position, focus: focusOverlay, holdKey: holdKey) {
            return
        }
        if target == "item-check", showNativeItemCheck(text: text, position: position) {
            return
        }
        sendToOverlay(text: text, target: target, position: position, focusOverlay: focusOverlay)
    }

    /// Exiled Exchange 2's widgets get the item (`MAIN->CLIENT::item-text`).
    private func sendToOverlay(text: String, target: String, position: CGPoint, focusOverlay: Bool) {
        send(.lastActive, try? IpcMessage(.itemText, ItemTextPayload(
            target: target, clipboard: text, x: position.x, y: position.y, focusOverlay: focusOverlay)))
        if focusOverlay && overlay.wasUsedRecently {
            overlay.activate(source: "copy-item")
        }
    }

    /// Item text pasted into the overlay bar's price check field: the native price check (focused, as
    /// the overlay is open), or Exiled Exchange 2's when the native one is off.
    func checkPastedItem(_ text: String) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center: CGPoint = status.gameRect.map {
            let quartz = ScreenCoordinates.cocoaRect(fromQuartz: $0, primaryHeight: primaryHeight)
            return CGPoint(x: quartz.midX, y: quartz.midY)
        } ?? .zero
        if showNativePriceCheck(text: text, position: center, focus: true, holdKey: nil) { return }
        send(.lastActive, try? IpcMessage(.itemText, ItemTextPayload(
            target: "price-check", clipboard: text, x: center.x, y: center.y, focusOverlay: true)))
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
        itemCheck?.hide()
        native.show(clipboard: text, cursor: position, game: game, focus: focus)
        if !focus {
            // Same behavior as upstream's track-area for the web widget (PriceCheckWindow.vue:265-288).
            areaTarget = .native
            areaModel.start(WidgetAreaModel.Area(holdKey: holdKey ?? "", closeThreshold: 40, from: position, rect: native.areaRect))
        }
        return true
    }

    /// Shows the item in the native item check if it's on. Maps and items the parser doesn't read go
    /// to Exiled Exchange 2 once the engine has looked at them. Returns false to send it there now.
    /// - Parameter fallbackArea: Cocoa rect to use when no game window is attached (debug runs).
    @discardableResult
    func showNativeItemCheck(text: String, position: CGPoint, fallbackArea: CGRect? = nil) -> Bool {
        guard let itemCheck,
              UserDefaults.standard.bool(forKey: Self.nativeItemCheckDefaultsKey),
              let gameCocoa = status.gameRect ?? fallbackArea
        else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let game = ScreenCoordinates.cocoaRect(fromQuartz: gameCocoa, primaryHeight: primaryHeight) // involution: Cocoa → Quartz
        Task { [weak self] in
            guard let self else { return }
            if await itemCheck.show(clipboard: text, cursor: position, game: game) {
                self.nativePriceCheck?.hide()
            } else {
                self.sendToOverlay(text: text, target: "item-check", position: position, focusOverlay: true)
            }
        }
        return true
    }

    // MARK: Pointer

    private func handlePointer(_ event: InputTap.PointerEvent) {
        if event.kind == .wheel {
            handleStashScroll(event)
            return
        }
        if event.kind == .moved && !event.alt {
            applyAlt(altModel.otherInput())
        }
        if event.kind == .down {
            nativePriceCheck?.mouseDown(atQuartz: event.location)
            itemCheck?.mouseDown(atQuartz: event.location)
        }
        guard areaModel.isTracking else { return }
        let effects: [WidgetAreaModel.Effect]
        let interactable = areaTarget == .native ? (nativePriceCheck?.isKey ?? false) : overlay.isInteractable
        switch event.kind {
        case .moved:
            effects = areaModel.mouseMoved(to: event.location, ctrl: event.ctrl, alt: event.alt, overlayInteractable: interactable)
        case .down:
            effects = areaModel.mouseDown(at: event.location)
        case .wheel:
            return // handled above
        }
        if areaTarget == .native, let native = nativePriceCheck {
            for effect in effects {
                switch effect {
                case .hideExclusiveWidget, .focusGame: if !native.isPinned { native.hide() }
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

    /// Ctrl + wheel outside the stash switches stash tabs with the arrow keys (Shortcuts.ts:96-106).
    private func handleStashScroll(_ event: InputTap.PointerEvent) {
        guard stashScroll, event.ctrl, overlay.isGameActive, let gameCocoa = status.gameRect,
              let key = StashScroll.arrowKey(physicalDelta: event.wheelDelta) else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let game = ScreenCoordinates.cocoaRect(fromQuartz: gameCocoa, primaryHeight: primaryHeight) // Cocoa → Quartz
        guard !StashScroll.isStashArea(event.location, game: game) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastStashScroll) >= StashScroll.minimumInterval else { return }
        lastStashScroll = now
        // Ctrl is physically held; keep it in the flags so Wine doesn't see it released.
        synthesizer.tap(key, alsoHeld: ["Ctrl"])
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
