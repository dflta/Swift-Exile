import AppKit
import SwiftUI
import ApplicationServices
import SwiftExileCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let status = HostStatus()
    /// Exiled Exchange 2's settings, edited from SwiftExile's window.
    let overlaySettings = OverlaySettingsStore()
    /// Persistent log (`~/Library/Logs/SwiftExile/swiftexile.log`), also for Finder launches.
    let logFile = LogFile()
    let updates = Updates()
    private let options = LaunchOptions.parse()
    private var hub: EventHub?
    private var webHost: WebViewHost?
    private var tracker: GameWindowTracker?
    private var overlay: OverlayController?
    private var shortcuts: ShortcutController?
    /// Game log (`Client.txt`) for the overlay's client-log features, and the library's data files.
    private var gameLog: GameLogController?
    private var experienceTracker: ExperienceTrackerController?
    /// Settings inside the open overlay (opened from SwiftExile's bar).
    private var inOverlaySettings: InOverlaySettingsController?
    /// SwiftExile's bar in the open overlay.
    private var overlayBar: OverlayBarController?
    private var browserWindow: NSWindow?
    private var trustTimer: Timer?

    private var signalSources: [DispatchSourceSignal] = []

    /// SIGTERM (kill, logout) and SIGINT (Ctrl+C in the diagnostics terminal) quit the app.
    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN) // let the dispatch source receive it instead
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private var nativePriceCheck: NativePriceCheckController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        UserDefaults.standard.register(defaults: [ShortcutController.nativePriceCheckDefaultsKey: true])
        // Not during scripted runs (snapshots, --quit-after): Sparkle may ask about automatic checks.
        if options.quitAfter == nil && options.nativeSnapshotPath == nil { updates.start() }
        // Info.plist sets LSUIElement (menu bar app, no Dock icon). The debug browser window
        // behaves like a normal app instead.
        if options.browserMode { NSApp.setActivationPolicy(.regular) }
        Task { await start() }
    }

    // MARK: Startup

    private func start() async {
        let logFile = self.logFile
        logFile.startSession("SwiftExile \(AppInfo.version) (EE2 \(AppInfo.upstreamVersion)), pid \(ProcessInfo.processInfo.processIdentifier)")
        let hub = EventHub(logSink: { line in
            FileHandle.standardOutput.write(Data(("[host] " + line).utf8))
            logFile.write(line)
        })
        self.hub = hub
        let configStore = ConfigStore(dataDir: options.dataDir, readOnly: options.devServerURL != nil)
        await wireEvents(hub: hub, configStore: configStore)
        await overlaySettings.attach(configStore: configStore, hub: hub)
        overlaySettings.onHostConfig = { [weak self] config in self?.applyHostConfig(config) }

        let configuration = HostServerConfiguration(
            host: options.listenHost,
            port: options.listenPort,
            rendererDir: options.devServerURL == nil ? options.rendererDir : nil,
            dataDir: options.dataDir,
            version: AppInfo.hostStateVersion,
            proxyUserAgent: AppInfo.proxyUserAgent,
            trace: { line in FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
        )
        let port: Int
        do {
            port = try await HostServer.start(configuration: configuration, hub: hub, configStore: configStore) {
                // SIGTERM / Ctrl+C stop the server; quit the whole app instead of leaving it running.
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } catch {
            FileHandle.standardError.write(Data("Failed to start server: \(error)\n".utf8))
            NSApp.terminate(nil)
            return
        }
        status.serverPort = port
        status.dataDir = options.dataDir.path
        await hub.log("info SwiftExile \(AppInfo.version) (EE2 \(AppInfo.upstreamVersion)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        await hub.log("info [Host] listening on http://\(options.listenHost):\(port), data dir \(options.dataDir.path)")
        if options.rendererDir == nil && options.devServerURL == nil {
            await hub.log("error [Host] renderer build not found; set SWIFTEXILE_RENDERER_DIR or bundle it")
        }

        let url = options.devServerURL ?? URL(string: "http://localhost:\(port)/index.html")!
        if options.browserMode {
            openBrowserWindow(url: url)
        } else {
            setUpOverlay(url: url, hub: hub)
        }
        scheduleDebugActions()
    }

    private func wireEvents(hub: EventHub, configStore: ConfigStore) async {
        await hub.on(.saveConfig) { [weak self] payload in
            guard let save = try? payload?.decode(SaveConfigPayload.self) else { return }
            await MainActor.run { self?.overlaySettings.savedByOverlay(contents: save.contents) }
            do {
                try await configStore.save(contents: save.contents, isTemporary: save.isTemporary)
            } catch {
                await hub.log("error [ConfigStore] Failed to save config: \(error.localizedDescription)")
            }
            if let changed = try? IpcMessage(.configChanged, ConfigChangedPayload(contents: save.contents)) {
                await hub.send(.broadcast, changed)
            }
        }
        await hub.on(.userAction) { [weak self] payload in
            guard let action = try? payload?.decode(UserActionPayload.self) else { return }
            if action.action == "quit" {
                await MainActor.run { NSApp.terminate(nil) }
            } else if action.action == "stash-search", let text = action.text {
                await MainActor.run { self?.shortcuts?.stashSearchFromOverlay(text) }
            }
        }
        await hub.on(.updateHostConfig) { [weak self] payload in
            guard let config = try? payload?.decode(HostConfig.self) else { return }
            await MainActor.run { self?.applyHostConfig(config) }
        }
        await hub.on(.reparseLog) { [weak self] _ in
            await MainActor.run { self?.gameLog?.reparse() }
        }
        await hub.on(.writeData) { [weak self] payload in
            guard let payload else { return }
            // The overlay reports what it understood from the game log; log zone changes and level
            // ups so client-log problems can be told apart (host not sending vs. overlay not parsing).
            if case .object(let fields) = payload, case .string("client-log-event")? = fields["action"],
               case .object(let event)? = fields["data"], case .string(let type)? = event["type"],
               type == "load-zone" || type == "level-up" {
                let detail = [event["zone"], event["areaLevel"], event["level"], event["charName"]]
                    .compactMap { value -> String? in
                        switch value {
                        case .string(let text)?: return text
                        case .number(let number)?: return String(Int(number))
                        default: return nil
                        }
                    }
                    .joined(separator: " ")
                await hub.log("info [GameLog] overlay saw \(type): \(detail)")
            }
            guard let writer = await MainActor.run(body: { self?.gameLog?.writer }) else { return }
            await writer.handle(payload)
        }
        await hub.on(.focusGame) { [weak self] _ in
            await MainActor.run { self?.overlay?.focusGame() }
        }
        await hub.on(.renderState) { [weak self] payload in
            guard let state = try? payload?.decode(RenderStatePayload.self) else { return }
            await MainActor.run { self?.overlay?.renderState(shouldShow: state.shouldShow) }
        }
        await hub.on(.trackArea) { [weak self] payload in
            guard let area = try? payload?.decode(TrackAreaPayload.self) else { return }
            await MainActor.run { self?.shortcuts?.trackArea(area) }
        }
        await hub.on(.usedRecently) { [weak self] payload in
            guard let used = try? payload?.decode(UsedRecentlyPayload.self) else { return }
            await MainActor.run { self?.overlay?.usedRecently(isOverlay: used.isOverlay) }
        }
    }

    private func setUpOverlay(url: URL, hub: EventHub) {
        let webHost = WebViewHost(userAgentSuffix: AppInfo.webUserAgentSuffix(browserMode: false), transparent: true)
        let tracker = GameWindowTracker(log: { line in Task { await hub.log(line) } })
        webHost.onConsoleProblem = { level, text in
            Task { await hub.log("\(level) [Renderer] \(text.prefix(2000))") }
        }
        webHost.onPaintLatency = { ms in
            Task { await hub.log(String(format: "debug [Renderer] price check painted %.0f ms after item text", ms)) }
        }
        let overlay = OverlayController(webHost: webHost, tracker: tracker, hub: hub, status: status)
        let shortcuts = ShortcutController(hub: hub, overlay: overlay, status: status)
        let gameLog = GameLogController(hub: hub, status: status, dataDir: options.dataDir)
        self.gameLog = gameLog
        let xpTracker = ExperienceTrackerController(model: gameLog.leveling, status: status)
        xpTracker.isEnabled = gameLog.nativeTracker
        experienceTracker = xpTracker
        hideWebExperienceWidget(gameLog.nativeTracker, webHost: webHost)
        if gameLog.nativeTracker { gameLog.setNativeTracker(true, save: false) }
        overlay.onGameAttached = { [weak shortcuts, weak gameLog] in
            shortcuts?.gameAttached()
            gameLog?.gameAttached()
        }
        // Native SwiftUI price check (preview), driven by upstream's logic in a hidden web view.
        let engine = PriceCheckEngine(serverPort: status.serverPort, log: { line in Task { await hub.log(line) } })
        let native = NativePriceCheckController(model: PriceCheckModel(engine: engine, log: { line in Task { await hub.log(line) } }))
        native.isGame = { [weak self] pid in self?.status.gamePid == pid }
        native.overlayWindowNumber = { [weak overlay] in overlay?.panel.windowNumber ?? 0 }
        shortcuts.nativePriceCheck = native
        nativePriceCheck = native
        Task { _ = try? await engine.start() } // warm up: item data and prices load before the first check
        self.webHost = webHost
        self.tracker = tracker
        self.overlay = overlay
        self.shortcuts = shortcuts
        let settingsInOverlay = InOverlaySettingsController(status: status, actions: self)
        let bar = OverlayBarController(status: status, actions: self)
        settingsInOverlay.onFocusChange = { [weak overlay] in overlay?.companionFocusChanged() }
        bar.onFocusChange = { [weak overlay] in overlay?.companionFocusChanged() }
        overlay.companionPanels = { [weak settingsInOverlay, weak bar] in
            var panels: [NSWindow] = []
            if let settingsInOverlay, settingsInOverlay.isVisible { panels.append(settingsInOverlay.panel) }
            if let bar, bar.panel.isKeyWindow { panels.append(bar.panel) }
            return panels
        }
        overlay.onOpenOverlayChange = { [weak self, weak settingsInOverlay, weak bar] open in
            // They come and go with the open overlay, like Exiled Exchange 2's widgets, including
            // when another app comes to the front. Settings left open come back with the overlay.
            if open {
                bar?.show()
                if let settingsInOverlay, settingsInOverlay.isOpen {
                    settingsInOverlay.show(over: self?.status.gameRect)
                }
            } else {
                bar?.hide()
                settingsInOverlay?.suspend()
            }
            self?.experienceTracker?.overlayOpenChanged(open)
        }
        inOverlaySettings = settingsInOverlay
        overlayBar = bar
        webHost.load(url)
        // Hotkeys from the settings file right away, before the web overlay has loaded and sent them.
        if let settings = overlaySettings.settings { applyHostConfig(settings.hostConfig()) }

        if AXIsProcessTrusted() {
            status.accessibilityTrusted = true
            tracker.start()
            shortcuts.start()
        } else {
            // Without Accessibility the server and browser mode still work (plan §2.10): wait,
            // don't quit like the Electron app does after 15 s.
            Task { await hub.log("warn [Host] Accessibility permission missing; waiting for it to be granted") }
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            // macOS prompts only once per app; a stale entry from an older (differently signed)
            // build gets no prompt at all. Show our Permissions tab with instructions after a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !AXIsProcessTrusted() else { return }
                self.showPermissionsWindow()
            }
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted(), let self else { return }
                    self.trustTimer?.invalidate()
                    self.trustTimer = nil
                    self.permissionsWindow?.close()
                    self.status.accessibilityTrusted = true
                    Task { await hub.log("info [Host] Accessibility permission granted") }
                    self.tracker?.start()
                    self.shortcuts?.start()
                }
            }
        }
    }

    private var permissionsWindow: NSWindow?

    /// Shows the SwiftUI Permissions view in its own window. (SwiftUI's Settings scene can only be
    /// opened from inside a view via `openSettings`; `showSettingsWindow:` no longer works.)
    private func showPermissionsWindow() {
        if permissionsWindow == nil {
            let view = PermissionsTab(status: status).frame(width: 520).fixedSize(horizontal: false, vertical: true)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "SwiftExile needs Accessibility access"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            permissionsWindow = window
        }
        NSApp.activate()
        permissionsWindow?.center()
        permissionsWindow?.makeKeyAndOrderFront(nil)
    }

    private func openBrowserWindow(url: URL) {
        let host = WebViewHost(userAgentSuffix: AppInfo.webUserAgentSuffix(browserMode: true), transparent: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SwiftExile (browser mode)"
        window.contentView = host.webView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        host.load(url)
        webHost = host
        browserWindow = window
    }

    /// Development switches for automated runs (see LaunchOptions).
    private func scheduleDebugActions() {
        if let path = options.snapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.snapshotDelay) { [weak self] in
                self?.webHost?.snapshot(to: URL(fileURLWithPath: path))
            }
        }
        if options.selfTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, options.snapshotDelay - 2)) { [weak self] in
                self?.webHost?.evaluate("window.dispatchEvent(new Event('blur')); document.title")
            }
        }
        if let toggleAt = options.toggleAt {
            DispatchQueue.main.asyncAfter(deadline: .now() + toggleAt) { [weak self] in
                self?.debugToggle(label: "toggle 1 (expect interactive)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + toggleAt + 2.5) { [weak self] in
                self?.debugState(label: "hold check 2.5 s after toggle 1 (expect still interactive)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + toggleAt + 3) { [weak self] in
                self?.debugToggle(label: "toggle 2 (expect back to game)")
            }
        }
        if let path = options.debugItemPath {
            for repeatIndex in 0..<max(1, options.debugItemRepeat) {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.debugItemAt + Double(repeatIndex) * 3) { [weak self] in
                guard let hub = self?.hub, let text = try? String(contentsOfFile: path, encoding: .utf8),
                      let message = try? IpcMessage(.itemText, ItemTextPayload(
                        target: "price-check", clipboard: text, x: 1200, y: 600, focusOverlay: false))
                else { return }
                Task {
                    await hub.log("debug [Host] sending debug item from \(path)")
                    await hub.send(.lastActive, message)
                }
            }
            }
        }
        if let path = options.debugNativeItemPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.debugItemAt) { [weak self] in
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
                let shown = self?.shortcuts?.showNativePriceCheck(text: text, position: CGPoint(x: 1800, y: 600), focus: true, holdKey: nil,
                                                                  fallbackArea: NSScreen.screens.first?.frame) ?? false
                if let hub = self?.hub { Task { await hub.log("debug [Host] native debug item \(shown ? "shown" : "not shown (game not attached or preview off)")") } }
            }
        }
        // Development: render every page of SwiftExile's window to PNGs in this folder.
        if let folder = ProcessInfo.processInfo.environment["SWIFTEXILE_SETTINGS_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self else { return }
                for page in SettingsView.Page.allCases {
                    let view = NSHostingView(rootView: SettingsView(status: self.status, actions: self, page: page))
                    let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 820, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
                    window.contentView = view
                    window.orderBack(nil)
                    view.layoutSubtreeIfNeeded()
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(page.rawValue).png"))
                    }
                    window.orderOut(nil)
                }
                if let bar = self.overlayBar?.panel.contentView {
                    bar.setFrameSize(bar.fittingSize)
                    bar.layoutSubtreeIfNeeded()
                    if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
                        bar.cacheDisplay(in: bar.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/overlay-bar.png"))
                    }
                }
                print("[snapshot] settings pages saved to \(folder)")
            }
        }
        if let path = options.nativeSnapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.snapshotDelay) { [weak self] in
                let saved = self?.nativePriceCheck?.snapshot(to: URL(fileURLWithPath: path)) ?? false
                print("[snapshot] native price check \(saved ? "saved \(path)" : "failed")")
            }
        }
        if let seconds = options.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    /// Hotkeys and options from the overlay's settings, whether the web overlay sent them or they
    /// were computed from the file after a change in SwiftExile's window.
    func applyHostConfig(_ config: HostConfig) {
        overlay?.hostConfigChanged(config)
        shortcuts?.hostConfigChanged(config)
        gameLog?.hostConfigChanged(config)
    }

    /// Runs a stash search from SwiftExile's window (the game gets focus first).
    func runStashSearch(_ text: String) {
        shortcuts?.stashSearchFromOverlay(text)
    }

    // MARK: SwiftExile window

    private var settingsCloseObserver: NSObjectProtocol?
    /// Opens the SwiftUI Settings scene; registered by the menu bar icon view at launch.
    var openSettingsAction: (() -> Void)?

    /// Item text pasted into the bar's price check field.
    func priceCheckPasted(_ text: String) {
        shortcuts?.checkPastedItem(text)
    }

    /// The bar's ⚙ button: settings inside the overlay, like Exiled Exchange 2's own.
    func openSettingsFromOverlay() {
        guard let inOverlaySettings else { return }
        if inOverlaySettings.isVisible {
            inOverlaySettings.hide()
        } else {
            inOverlaySettings.show(over: status.gameRect)
        }
    }

    /// Opens SwiftExile's window from the menu bar on the first click. macOS activates apps
    /// cooperatively, and the game (under Wine) doesn't give up being frontmost, so a plain
    /// `NSApp.activate()` is often refused and the window stays behind the game. While the window is
    /// open SwiftExile is a regular app (Dock icon, ⌘-Tab); it returns to the menu bar when closed.
    func presentSettings(open: () -> Void) {
        if !options.browserMode { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        open()
        // SwiftUI creates the window asynchronously.
        for delay in [0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.bringSettingsToFront() }
        }
    }

    private func bringSettingsToFront() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("Settings") == true }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        guard settingsCloseObserver == nil else { return }
        settingsCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.settingsCloseObserver { NotificationCenter.default.removeObserver(observer) }
                self.settingsCloseObserver = nil
                if !self.options.browserMode { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    /// Settings ▸ Leveling ▸ Experience tracker.
    func experienceTrackerChanged(_ on: Bool) {
        gameLog?.setNativeTracker(on)
        experienceTracker?.isEnabled = on
        if let webHost { hideWebExperienceWidget(on, webHost: webHost) }
    }

    /// While the native tracker is on, Exiled Exchange 2's own XP widget would sit in the same
    /// place, so it's hidden on the overlay page (CSS only; the shared settings file is untouched).
    /// Upstream's CSS module classes keep their source names ("_xpContainer_<hash>").
    private func hideWebExperienceWidget(_ hide: Bool, webHost: WebViewHost) {
        webHost.setPageStyle("hide-xp-widget", css: hide
            ? #"[class*="_widget_"]:has(> [class*="_xpContainer_"]) { display: none !important; }"#
            : nil)
    }

    /// The game log SwiftExile follows, if any (shown in Settings).
    var followedGameLog: String? { gameLog?.followedLog }

    /// Settings ▸ Price Check ▸ Show prices in.
    func priceCurrencyChanged(_ currency: PriceCurrency) {
        guard let model = nativePriceCheck?.model else { return }
        Task { await model.setPriceCurrency(currency) }
    }

    private func debugToggle(label: String) {
        overlay?.toggle(source: "debug")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.debugState(label: label)
        }
    }

    private func debugState(label: String) {
        guard let overlay, let hub else { return }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let line = "debug [Overlay] \(label): interactable=\(status.overlayInteractable) visible=\(status.overlayVisible) panelKey=\(overlay.panel.isKeyWindow) ignoresMouse=\(overlay.panel.ignoresMouseEvents) frontmost=\(front) appActive=\(NSApp.isActive) gameActive=\(status.gameFocused)"
        Task { await hub.log(line) }
    }

    // MARK: Actions (menu bar)

    func toggleOverlay() {
        overlay?.toggle()
    }

    func openInBrowser() {
        guard status.serverPort > 0, let url = URL(string: "http://localhost:\(status.serverPort)") else { return }
        NSWorkspace.shared.open(url)
    }

    func openDataFolder() {
        try? FileManager.default.createDirectory(at: options.dataDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(options.dataDir)
    }

    func openLogFile() {
        logFile.flush()
        NSWorkspace.shared.open(logFile.url)
    }

    func openLicenses() {
        if let licenses = Bundle.main.resourceURL?.appendingPathComponent("Licenses"),
           FileManager.default.fileExists(atPath: licenses.path) {
            NSWorkspace.shared.open(licenses)
        } else if let url = URL(string: "https://github.com/Kvan7/Exiled-Exchange-2/blob/master/LICENSE") {
            NSWorkspace.shared.open(url)
        }
    }
}
