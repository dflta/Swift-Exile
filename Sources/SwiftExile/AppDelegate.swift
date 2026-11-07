import AppKit
import SwiftUI
import ApplicationServices
import SwiftExileCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let status = HostStatus()
    /// Persistent log (`~/Library/Logs/SwiftExile/swiftexile.log`), also for Finder launches.
    let logFile = LogFile()
    private let options = LaunchOptions.parse()
    private var hub: EventHub?
    private var webHost: WebViewHost?
    private var tracker: GameWindowTracker?
    private var overlay: OverlayController?
    private var shortcuts: ShortcutController?
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
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
        await hub.on(.saveConfig) { payload in
            guard let save = try? payload?.decode(SaveConfigPayload.self) else { return }
            do {
                try await configStore.save(contents: save.contents, isTemporary: save.isTemporary)
            } catch {
                await hub.log("error [ConfigStore] Failed to save config: \(error.localizedDescription)")
            }
            if let changed = try? IpcMessage(.configChanged, ConfigChangedPayload(contents: save.contents)) {
                await hub.send(.broadcast, changed)
            }
        }
        await hub.on(.userAction) { payload in
            guard let action = try? payload?.decode(UserActionPayload.self) else { return }
            if action.action == "quit" {
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
        await hub.on(.updateHostConfig) { [weak self] payload in
            guard let config = try? payload?.decode(HostConfig.self) else { return }
            await MainActor.run {
                self?.overlay?.hostConfigChanged(config)
                self?.shortcuts?.hostConfigChanged(config)
            }
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
        webHost.onPaintLatency = { ms in
            Task { await hub.log(String(format: "debug [Renderer] price check painted %.0f ms after item text", ms)) }
        }
        let overlay = OverlayController(webHost: webHost, tracker: tracker, hub: hub, status: status)
        let shortcuts = ShortcutController(hub: hub, overlay: overlay, status: status)
        overlay.onGameAttached = { [weak shortcuts] in shortcuts?.gameAttached() }
        self.webHost = webHost
        self.tracker = tracker
        self.overlay = overlay
        self.shortcuts = shortcuts
        webHost.load(url)

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
        if let seconds = options.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
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
