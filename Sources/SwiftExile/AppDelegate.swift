import AppKit
import SwiftExileCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private var window: NSWindow?
    private var webHost: WebViewHost?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        Task { await start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func start() async {
        let hub = EventHub(logSink: { line in FileHandle.standardOutput.write(Data(("[host] " + line).utf8)) })
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
        do {
            let port = try await HostServer.start(configuration: configuration, hub: hub, configStore: configStore)
            await hub.log("info SwiftExile \(AppInfo.version) (EE2 \(AppInfo.upstreamVersion)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            await hub.log("info [Host] listening on http://\(options.listenHost):\(port), data dir \(options.dataDir.path)")
            if options.rendererDir == nil && options.devServerURL == nil {
                await hub.log("error [Host] renderer build not found; set SWIFTEXILE_RENDERER_DIR or bundle it")
            }
            let url = options.devServerURL ?? URL(string: "http://localhost:\(port)/index.html")!
            openWindow(url: url)
        } catch {
            FileHandle.standardError.write(Data("Failed to start server: \(error)\n".utf8))
            NSApp.terminate(nil)
        }
    }

    /// Day-1 wiring. Overlay, shortcuts, and file watchers come in later milestones.
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
        await hub.on(.updateHostConfig) { _ in
            await hub.log("debug [Host] host config received (not applied yet: no overlay or shortcuts on day 1)")
        }
    }

    private func openWindow(url: URL) {
        let host = WebViewHost(userAgentSuffix: AppInfo.webUserAgentSuffix(browserMode: options.browserMode))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SwiftExile"
        window.contentView = host.webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        host.load(url)
        self.window = window
        self.webHost = host

        if let path = options.snapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.snapshotDelay) { [weak host] in
                host?.snapshot(to: URL(fileURLWithPath: path))
            }
        }
        if options.selfTest {
            // Fires the renderer's own save path: OverlayWindow.vue saves the config on window blur.
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, options.snapshotDelay - 2)) { [weak host] in
                host?.evaluate("window.dispatchEvent(new Event('blur')); document.title")
            }
        }
        if let seconds = options.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }
}

enum MainMenu {
    @MainActor
    static func make() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit SwiftExile", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Edit menu so ⌘C/⌘V/⌘A work in renderer inputs (parity with OverlayWindow.ts:55-61).
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload", action: #selector(WebViewHost.reloadPage(_:)), keyEquivalent: "r")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        return main
    }
}
