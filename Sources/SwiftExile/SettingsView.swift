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
            PriceCheckTab(actions: actions)
                .tabItem { Label("Price Check", systemImage: "tag") }
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

private struct PriceCheckTab: View {
    let actions: AppDelegate
    @AppStorage(ShortcutController.nativePriceCheckDefaultsKey) private var nativePriceCheck = true
    @AppStorage(PriceCurrency.defaultsKey) private var priceCurrency = PriceCurrency.auto.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Native price check (preview)", isOn: $nativePriceCheck)
                Picker("Show prices in", selection: $priceCurrency) {
                    ForEach(PriceCurrency.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: priceCurrency) { _, newValue in
                    actions.priceCurrencyChanged(PriceCurrency(rawValue: newValue) ?? .auto)
                }
            } footer: {
                Text("Automatic shows divines from about 1 divine up and your core currency below, like Exiled Exchange 2. Applies to poe.ninja prices in the native price check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

struct PermissionsTab: View {
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
                LabeledContent {
                    if status.hotkeysAvailable {
                        Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("Not available").foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Global hotkeys")
                    Text(status.registeredHotkeys.isEmpty ? "No hotkeys registered yet." : status.registeredHotkeys.joined(separator: ", "))
                }
            } footer: {
                if !status.accessibilityTrusted {
                    Text("After granting, SwiftExile picks it up automatically. If macOS shows no prompt, SwiftExile is probably already listed from an older build: in System Settings ▸ Privacy & Security ▸ Accessibility, select SwiftExile, remove it with “−”, then add it again with “+” (or switch it off and on).")
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
                LabeledContent("Copyright", value: "© 2026 dflta. PolyForm Noncommercial 1.0.0.")
            }
            if actions.updates.canCheck {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { actions.updates.automaticallyChecks },
                        set: { actions.updates.automaticallyChecks = $0 }))
                    Button("Check for Updates…") { actions.updates.checkForUpdates() }
                }
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
