import Foundation
import SwiftExileCore

/// Command-line flags (parity with upstream `docs/cmd-flags.md`) plus development switches.
struct LaunchOptions {
    var listenHost = "127.0.0.1"
    var listenPort = 0
    /// Vite dev server URL (`SWIFTEXILE_DEV_SERVER_URL`); the host then listens on 8584 like upstream dev mode.
    var devServerURL: URL?
    var rendererDir: URL?
    var dataDir: URL
    /// Omit the `Electron` UA token, so the renderer runs as a plain browser client (day-1 testing).
    var browserMode = false
    var snapshotPath: String?
    var snapshotDelay: Double = 8
    var quitAfter: Double?
    /// Development check: triggers the renderer's config save before the snapshot.
    var selfTest = false
    /// Development check: toggle the overlay at this many seconds, and back 3 s later.
    var toggleAt: Double?
    /// Development check: send this file's text to the renderer as a copied item (no game needed).
    var debugItemPath: String?
    var debugItemAt: Double = 6
    /// Send the debug item this many times, 3 s apart (latency measurements).
    var debugItemRepeat = 1
    /// Development check: show this file's item in the native price check.
    var debugNativeItemPath: String?
    /// Development check: render the native price check to this PNG after `snapshotDelay`.
    var nativeSnapshotPath: String?
    /// Development check: show this file's item in the native item check, and render it to
    /// `itemCheckSnapshotPath` after `snapshotDelay`.
    var debugItemCheckPath: String?
    var itemCheckSnapshotPath: String?

    static func parse(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LaunchOptions {
        var options = LaunchOptions(dataDir: HostPaths.dataDir(environment: environment))

        if let dev = environment["SWIFTEXILE_DEV_SERVER_URL"], let url = URL(string: dev) {
            options.devServerURL = url
            options.listenPort = 8584
        }
        if let dir = environment["SWIFTEXILE_RENDERER_DIR"], !dir.isEmpty {
            options.rendererDir = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        } else if let bundled = Bundle.main.resourceURL?.appendingPathComponent("renderer", isDirectory: true),
                  FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            options.rendererDir = bundled
        }

        for argument in arguments.dropFirst() {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : nil
            switch parts[0] {
            case "--listen":
                // --listen=[host][:port] (server.ts:133-139)
                let hostPort = (value ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                if let host = hostPort.first, !host.isEmpty { options.listenHost = host }
                if hostPort.count > 1, let port = Int(hostPort[1]) { options.listenPort = port }
            case "--browser-mode":
                options.browserMode = true
            case "--snapshot":
                options.snapshotPath = value
            case "--snapshot-delay":
                options.snapshotDelay = Double(value ?? "") ?? options.snapshotDelay
            case "--quit-after":
                options.quitAfter = Double(value ?? "")
            case "--selftest":
                options.selfTest = true
            case "--toggle-at":
                options.toggleAt = Double(value ?? "")
            case "--debug-item":
                options.debugItemPath = value
            case "--debug-native-item":
                options.debugNativeItemPath = value
            case "--native-snapshot":
                options.nativeSnapshotPath = value
            case "--debug-item-check":
                options.debugItemCheckPath = value
            case "--item-check-snapshot":
                options.itemCheckSnapshotPath = value
            case "--debug-item-repeat":
                options.debugItemRepeat = Int(value ?? "") ?? 1
            case "--debug-item-at":
                options.debugItemAt = Double(value ?? "") ?? options.debugItemAt
            default:
                break
            }
        }
        return options
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0-dev"
    }

    static var upstreamVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "EE2UpstreamVersion") as? String ?? "unknown"
    }

    /// Shown by the renderer's About page (`about.vue:150`).
    static var hostStateVersion: String { "SwiftExile \(version) · EE2 \(upstreamVersion)" }

    /// Appended to WebKit's UA. The `Electron` token makes `Host.isElectron` true (`IPC.ts:88-90`),
    /// which turns on the renderer's overlay mode without changing the renderer.
    static func webUserAgentSuffix(browserMode: Bool) -> String {
        browserMode
            ? "SwiftExile/\(version)"
            : "SwiftExile/\(version) EE2MacHost/\(version) Electron/0"
    }

    /// Chromium-shaped UA for proxied requests (open question Q8 in the plan).
    static var proxyUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "SwiftExile/\(version) Chrome/144.0.0.0 Safari/537.36"
    }
}
