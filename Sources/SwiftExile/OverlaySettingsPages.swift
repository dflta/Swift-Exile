import SwiftExileCore
import SwiftUI

// MARK: Bindings into Exiled Exchange 2's settings

extension OverlaySettingsStore {
    /// A top-level string ("" ↔ null, like upstream's optional paths).
    func text(_ key: String, fallback: String = "") -> Binding<String> {
        Binding(
            get: { self.settings?[string: key] ?? fallback },
            set: { value in self.update { $0[string: key] = value.isEmpty ? (fallback.isEmpty ? nil : fallback) : value } })
    }

    func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { self.settings?[bool: key] ?? false }, set: { value in self.update { $0[bool: key] = value } })
    }

    func hotkey(_ key: String) -> Binding<String?> {
        Binding(get: { self.settings?[string: key] }, set: { value in self.update { $0[string: key] = value } })
    }

    func widgetBool(_ type: String, _ key: String, fallback: Bool = false) -> Binding<Bool> {
        Binding(
            get: { OverlaySettings.bool(self.settings?.widget(type)?[key], default: fallback) },
            set: { value in self.update { $0.updateWidget(type) { $0[key] = .bool(value) } } })
    }

    func widgetNumber(_ type: String, _ key: String, fallback: Double) -> Binding<Double> {
        Binding(
            get: { OverlaySettings.number(self.settings?.widget(type)?[key]) ?? fallback },
            set: { value in self.update { $0.updateWidget(type) { $0[key] = .number(value) } } })
    }

    func widgetText(_ type: String, _ key: String, fallback: String) -> Binding<String> {
        Binding(
            get: { OverlaySettings.string(self.settings?.widget(type)?[key]) ?? fallback },
            set: { value in self.update { $0.updateWidget(type) { $0[key] = .string(value) } } })
    }

    func widgetHotkey(_ type: String, _ key: String) -> Binding<String?> {
        Binding(
            get: { OverlaySettings.string(self.settings?.widget(type)?[key]) },
            set: { value in self.update { $0.updateWidget(type) { $0[key] = value.map(JSONValue.string) ?? .null } } })
    }
}

// MARK: Hotkeys

struct HotkeysPage: View {
    let store: OverlaySettingsStore
    @AppStorage(ShortcutController.nativeItemCheckDefaultsKey) private var nativeItemCheck = true

    var body: some View {
        Form {
            Section("Price check") {
                LabeledContent("Auto-hide mode") {
                    HStack(spacing: 6) {
                        Picker("Hold", selection: store.widgetText("price-check", "hotkeyHold", fallback: "Alt")) {
                            Text("Ctrl").tag("Ctrl")
                            Text("Alt").tag("Alt")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Text("+").foregroundStyle(.secondary)
                        HotkeyField(hotkey: store.widgetHotkey("price-check", "hotkey"), keyOnly: true) { key in
                            "\(store.settings.flatMap { OverlaySettings.string($0.widget("price-check")?["hotkeyHold"]) } ?? "Alt") + \(key)"
                        }
                    }
                }
                .help("Hold the modifier while the price check is open; it closes when you release it and move away")
                LabeledContent("Open without auto-hide") {
                    HotkeyField(hotkey: store.widgetHotkey("price-check", "hotkeyLocked"))
                }
            }
            Section {
                LabeledContent("Item check") {
                    HotkeyField(hotkey: store.widgetHotkey("item-check", "hotkey"))
                }
                .help("Shows the item's modifiers and tiers, links, and stash searches")
                Toggle("Native item check", isOn: $nativeItemCheck)
                    .help("Off: Exiled Exchange 2's item info. Maps and contracts always use Exiled Exchange 2's map check")
                LabeledContent("Open on the wiki") { HotkeyField(hotkey: store.widgetHotkey("item-check", "wikiKey")) }
                LabeledContent("Open on poe2db") { HotkeyField(hotkey: store.widgetHotkey("item-check", "poedbKey")) }
                LabeledContent("Open on Craft of Exile") { HotkeyField(hotkey: store.widgetHotkey("item-check", "craftOfExileKey")) }
                LabeledContent {
                    HotkeyField(hotkey: store.widgetHotkey("item-check", "stashSearchKey"))
                } label: {
                    Text("Find in stash")
                    Text("Under Wine the game keeps the copied item on its clipboard for about 2 s, so the name is typed into the stash search instead of pasted. If your keyboard layout can't type it, it's pasted after that wait.")
                }
                LabeledContent("Find same price in stash") {
                    HStack(spacing: 6) {
                        Picker("Search for", selection: store.widgetText("item-check", "samePricedType", fallback: "both")) {
                            Text("Price").tag("price")
                            Text("Price and item").tag("both")
                        }
                        .labelsHidden()
                        .fixedSize()
                        HotkeyField(hotkey: store.widgetHotkey("item-check", "samePricedKey"))
                    }
                }
            } header: {
                Text("Item check")
            } footer: {
                Text("Craft of Exile links work with the game in English.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Overlay") {
                    HotkeyField(hotkey: Binding(
                        get: { store.settings?[string: "overlayKey"] },
                        set: { value in if let value { store.update { $0[string: "overlayKey"] = value } } }))
                }
                Toggle("Ctrl + mouse wheel switches stash tabs", isOn: store.flag("stashScroll"))
                Toggle("Restore the clipboard after copying or pasting", isOn: store.flag("restoreClipboard"))
            } header: {
                Text("General")
            } footer: {
                Text("Hotkeys work while the game is in front. The game's own keys (Ctrl + C, Ctrl + V, Enter, arrow keys…) can't be used. Chat and stash search hotkeys are on their own pages; the map check and other Exiled Exchange 2 widgets are set up in the overlay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !store.hotkeyProblems.isEmpty {
                Section("Problems") {
                    ForEach(store.hotkeyProblems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Chat commands

struct ChatCommandsPage: View {
    let store: OverlaySettingsStore

    private var commands: [OverlaySettings.Command] { store.settings?.commands ?? [] }

    var body: some View {
        Form {
            Section {
                ForEach(commands.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField("Command", text: binding(index, \.text), prompt: Text("/hideout"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                        HotkeyField(hotkey: binding(index, \.hotkey))
                        Toggle("Send", isOn: binding(index, \.send))
                            .toggleStyle(.checkbox)
                            .help("Press Enter after pasting (otherwise the text stays in the chat box)")
                        Button {
                            store.update { settings in
                                var list = settings.commands
                                list.remove(at: index)
                                settings.commands = list
                            }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
                Button {
                    store.update { $0.commands = $0.commands + [.init(text: "", hotkey: nil, send: true)] }
                } label: {
                    Label("Add command", systemImage: "plus")
                }
            } footer: {
                Text("“@last” stands for the last player who whispered you: “@last ty” replies to them, “/invite @last” invites them. Commands starting with # % @ $ & / pick their channel themselves.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ index: Int, _ path: WritableKeyPath<OverlaySettings.Command, Value>) -> Binding<Value> {
        Binding(
            get: { commands.indices.contains(index) ? commands[index][keyPath: path] : OverlaySettings.Command(text: "", hotkey: nil, send: true)[keyPath: path] },
            set: { value in
                store.update { settings in
                    var list = settings.commands
                    guard list.indices.contains(index) else { return }
                    list[index][keyPath: path] = value
                    settings.commands = list
                }
            })
    }
}

// MARK: Stash search

struct StashSearchPage: View {
    let store: OverlaySettingsStore
    let actions: AppDelegate

    private var widgetIDs: [Double] {
        (store.settings?.widgets("stash-search") ?? []).compactMap { OverlaySettings.number($0["wmId"]) }
    }

    var body: some View {
        Form {
            if widgetIDs.isEmpty {
                Section {
                    Text("No stash search widget yet. Add one in the overlay: widget menu ▸ … ▸ Add ▸ Stash search.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(widgetIDs.enumerated()), id: \.element) { number, id in
                Section {
                    Toggle("Hotkeys", isOn: enabledBinding(id))
                    ForEach(entries(id).indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            TextField("Name", text: entryBinding(id, index, \.name), prompt: Text("Name"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .multilineTextAlignment(.leading)
                                .frame(width: 130)
                            TextField("Search", text: entryBinding(id, index, \.text), prompt: Text("search text or regex"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .multilineTextAlignment(.leading)
                            HotkeyField(hotkey: entryBinding(id, index, \.hotkey))
                            Button {
                                actions.runStashSearch(entries(id)[index].text)
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(entries(id)[index].text.isEmpty)
                            .help("Search the open stash in the game now")
                            Button {
                                var list = entries(id)
                                list.remove(at: index)
                                store.update { $0.setStashSearchEntries(list, widgetID: id) }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                    Button {
                        var list = entries(id)
                        let next = (list.map(\.id).max() ?? 0) + 1
                        list.append(.init(id: next, name: "", text: "", hotkey: nil))
                        store.update { $0.setStashSearchEntries(list, widgetID: id) }
                    } label: {
                        Label("Add search", systemImage: "plus")
                    }
                } header: {
                    Text(widgetIDs.count > 1 ? "Stash search \(number + 1)" : "Stash search")
                }
            }
            Section {
            } footer: {
                Text("Open your stash in the game, then press a hotkey or ▶: SwiftExile types the search into the stash's search box (Ctrl + F).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func entries(_ id: Double) -> [OverlaySettings.StashSearchEntry] {
        store.settings?.stashSearchEntries(widgetID: id) ?? []
    }

    private func enabledBinding(_ id: Double) -> Binding<Bool> {
        Binding(
            get: {
                let widget = store.settings?.widgets("stash-search").first { OverlaySettings.number($0["wmId"]) == id }
                return OverlaySettings.bool(widget?["enableHotkeys"], default: true)
            },
            set: { value in store.update { $0.updateWidget("stash-search", id: id) { $0["enableHotkeys"] = .bool(value) } } })
    }

    private func entryBinding<Value>(_ id: Double, _ index: Int,
                                     _ path: WritableKeyPath<OverlaySettings.StashSearchEntry, Value>) -> Binding<Value> {
        Binding(
            get: {
                let list = entries(id)
                return list.indices.contains(index) ? list[index][keyPath: path]
                    : OverlaySettings.StashSearchEntry(id: 0, name: "", text: "", hotkey: nil)[keyPath: path]
            },
            set: { value in
                var list = entries(id)
                guard list.indices.contains(index) else { return }
                list[index][keyPath: path] = value
                store.update { $0.setStashSearchEntries(list, widgetID: id) }
            })
    }
}
