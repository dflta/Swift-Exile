import ApplicationServices
import SwiftExileCore
import SwiftUI

/// Native macOS Settings window. Game and widget settings still live in the overlay for now;
/// they move here as widgets are rebuilt in SwiftUI.
struct SettingsView: View {
    let status: HostStatus
    let actions: AppDelegate

    var body: some View {
        TabView {
            GameTab(status: status)
                .tabItem { Label("Game", systemImage: "gamecontroller") }
            PermissionsTab(status: status)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            AboutTab(actions: actions)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GameTab: View {
    let status: HostStatus

    var body: some View {
        Form {
            Section("Path of Exile 2") {
                LabeledContent("Status") {
                    if status.isAttached {
                        Label("Attached", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Not running", systemImage: "circle.dashed").foregroundStyle(.secondary)
                    }
                }
                if let appName = status.gameAppName {
                    LabeledContent("Process", value: appName)
                    LabeledContent("Setup", value: status.gameFlavor.displayName)
                }
                if let rect = status.gameRect {
                    LabeledContent("Overlay area", value: "\(Int(rect.width)) × \(Int(rect.height)) at \(Int(rect.minX)), \(Int(rect.minY))")
                }
                LabeledContent("Overlay") {
                    Text(status.overlayInteractable ? "Interactive" : (status.overlayVisible ? "Click-through" : "Hidden"))
                }
            }
            Section("Detected files") {
                PathRow(title: "Game settings", path: status.derivedConfigPath)
                PathRow(title: "Game log", path: status.derivedLogPath)
            }
            Section("SwiftExile") {
                PathRow(title: "Settings folder", path: status.dataDir)
                LabeledContent("Local server", value: status.serverPort > 0 ? "127.0.0.1:\(status.serverPort)" : "Starting…")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PathRow: View {
    let title: String
    let path: String?

    var body: some View {
        LabeledContent(title) {
            if let path, !path.isEmpty {
                Text(path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text("Not found").foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionsTab: View {
    let status: HostStatus

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if status.accessibilityTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { requestAccessibility() }
                    }
                } label: {
                    Text("Accessibility")
                    Text("Needed to follow the game window and, later, for hotkeys.")
                }
            } footer: {
                if !status.accessibilityTrusted {
                    Text("After granting, SwiftExile picks it up automatically. If it is already listed in System Settings but not working, remove it with “−” and add it again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct AboutTab: View {
    let actions: AppDelegate

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("Exiled Exchange 2", value: AppInfo.upstreamVersion)
            }
            Section("Credits") {
                Text("SwiftExile is a native macOS host for Exiled Exchange 2 by Kvan7, itself a fork of Awakened PoE Trade by SnosMe. The price check, item parser, and widgets come from Exiled Exchange 2. Not affiliated with or endorsed by Grinding Gear Games.")
                    .fixedSize(horizontal: false, vertical: true)
                Link("Exiled Exchange 2 on GitHub", destination: URL(string: "https://github.com/Kvan7/Exiled-Exchange-2")!)
                Link("Awakened PoE Trade on GitHub", destination: URL(string: "https://github.com/SnosMe/awakened-poe-trade")!)
                Button("Show Licenses") { actions.openLicenses() }
            }
        }
        .formStyle(.grouped)
    }
}
