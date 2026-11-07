import ApplicationServices
import SwiftExileCore
import SwiftUI

/// SwiftExile's window (Settings, ⌘,): SwiftExile's own settings plus the parts of Exiled Exchange 2's
/// overlay settings that SwiftExile implements natively. Overlay settings are saved to the same file
/// the overlay uses and stay in sync with it.
struct SettingsView: View {
    let status: HostStatus
    let actions: AppDelegate
    @State private var page: Page?

    init(status: HostStatus, actions: AppDelegate, page: Page = .game) {
        self.status = status
        self.actions = actions
        _page = State(initialValue: page)
    }

    enum Page: String, CaseIterable, Identifiable {
        case game, hotkeys, priceCheck, chat, stashSearch, leveling, permissions, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .game: return "Game"
            case .hotkeys: return "Hotkeys"
            case .priceCheck: return "Price Check"
            case .chat: return "Chat Commands"
            case .stashSearch: return "Stash Search"
            case .leveling: return "Leveling"
            case .permissions: return "Permissions"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .game: return "gamecontroller"
            case .hotkeys: return "keyboard"
            case .priceCheck: return "tag"
            case .chat: return "text.bubble"
            case .stashSearch: return "magnifyingglass"
            case .leveling: return "chart.line.uptrend.xyaxis"
            case .permissions: return "lock.shield"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            detail
                .navigationTitle(page?.title ?? "SwiftExile")
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    @ViewBuilder
    private var detail: some View {
        let store = actions.overlaySettings
        switch page ?? .game {
        case .game: GameTab(status: status, store: store)
        case .hotkeys: OverlaySettingsPage(store: store) { HotkeysPage(store: store) }
        case .priceCheck: PriceCheckTab(actions: actions, store: store)
        case .chat: OverlaySettingsPage(store: store) { ChatCommandsPage(store: store) }
        case .stashSearch: OverlaySettingsPage(store: store) { StashSearchPage(store: store, actions: actions) }
        case .leveling: LevelingTab(actions: actions, store: store)
        case .permissions: PermissionsTab(status: status)
        case .about: AboutTab(actions: actions)
        }
    }
}

/// Shows `content` once Exiled Exchange 2's settings file exists (the overlay creates it on first run).
private struct OverlaySettingsPage<Content: View>: View {
    let store: OverlaySettingsStore
    @ViewBuilder let content: () -> Content

    var body: some View {
        if store.settings == nil {
            ContentUnavailableView("No overlay settings yet", systemImage: "doc.badge.gearshape",
                                   description: Text("Exiled Exchange 2 creates its settings the first time the overlay runs. Start SwiftExile with the game once, then come back."))
        } else {
            content()
                .environment(\.hotkeySettings, store)
        }
    }
}

private struct GameTab: View {
    let status: HostStatus
    let store: OverlaySettingsStore

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
            if store.settings != nil {
                Section {
                    TextField("Game window title", text: store.text("windowTitle", fallback: "Path of Exile 2"))
                    TextField("Game settings file", text: store.text("gameConfig"), prompt: Text("Found automatically"))
                    TextField("Game log file", text: store.text("clientLog"), prompt: Text("Found automatically"))
                } header: {
                    Text("Overrides")
                } footer: {
                    Text("Leave the files empty to use the ones found next to the running game. Saved in Exiled Exchange 2's settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
    let store: OverlaySettingsStore
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
            if store.settings != nil {
                Section {
                    Toggle("Search right away in auto-hide mode", isOn: store.widgetBool("price-check", "smartInitialSearch", fallback: true))
                    Toggle("Search right away in locked mode", isOn: store.widgetBool("price-check", "lockedInitialSearch", fallback: true))
                    Stepper(value: store.widgetNumber("price-check", "searchStatRange", fallback: 10), in: 0...50) {
                        LabeledContent("Stat range", value: "±\(Int(store.widgetNumber("price-check", "searchStatRange", fallback: 10).wrappedValue)) %")
                    }
                    Toggle("Select all stats by default", isOn: store.widgetBool("price-check", "defaultAllSelected"))
                    Toggle("Always show modifier tiers", isOn: store.widgetBool("price-check", "alwaysShowTier"))
                    Toggle("Use the stack size as the minimum stock (bulk)", isOn: store.widgetBool("price-check", "activateStockFilter"))
                    Picker("Group listings by seller", selection: store.widgetText("price-check", "collapseListings", fallback: "api")) {
                        Text("Trade site").tag("api")
                        Text("SwiftExile").tag("app")
                    }
                } header: {
                    Text("Search")
                } footer: {
                    Text("“Right away” searches uniques, currency, and similar items as soon as the price check opens. Hotkeys are on the Hotkeys page. Saved in Exiled Exchange 2's settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LevelingTab: View {
    let actions: AppDelegate
    let store: OverlaySettingsStore
    @AppStorage(GameLogController.nativeTrackerKey) private var tracker = false

    var body: some View {
        Form {
            Section {
                Toggle("Experience tracker", isOn: $tracker)
                    .onChange(of: tracker) { _, on in actions.experienceTrackerChanged(on) }
                if tracker {
                    LabeledContent("Game log", value: actions.followedGameLog ?? "Found when the game is running")
                        .textSelection(.enabled)
                }
            } footer: {
                Text("Shows your level, the experience you get in the current area, and how far over the ideal area level you are, above the experience bar while you play. It reads the game's Client.txt (which also contains chat) on this Mac only; nothing is sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if store.settings != nil {
                Section {
                    Toggle("Let Exiled Exchange 2's widgets read Client.txt", isOn: store.flag("readClientLog"))
                    TextField("Game log file", text: store.text("clientLog"), prompt: Text("Found automatically"))
                } footer: {
                    Text("Exiled Exchange 2's own leveling widgets in the overlay. While the experience tracker above is on, its XP widget is hidden so the two don't overlap.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
