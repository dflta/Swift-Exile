import Foundation

/// Exiled Exchange 2's settings file (`apt-data/config.json`), edited natively.
///
/// Kept as untyped JSON so every key SwiftExile doesn't know (other widgets, newer upstream
/// options) survives a save unchanged. Typed accessors cover what the native window edits.
public struct OverlaySettings: Equatable, Sendable {
    public var root: [String: JSONValue]

    public init(root: [String: JSONValue]) { self.root = root }

    public init?(json text: String) {
        guard let data = text.data(using: .utf8),
              case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        self.root = root
    }

    /// JSON for `config.json` and `MAIN->CLIENT::config-changed`.
    public func serialized() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(root)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Top-level values

    public subscript(string key: String) -> String? {
        get { if case .string(let value)? = root[key] { return value }; return nil }
        set { root[key] = newValue.map(JSONValue.string) ?? .null }
    }

    public subscript(bool key: String) -> Bool {
        get { if case .bool(let value)? = root[key] { return value }; return false }
        set { root[key] = .bool(newValue) }
    }

    // MARK: Widgets

    public func widget(_ type: String) -> [String: JSONValue]? {
        guard case .array(let widgets)? = root["widgets"] else { return nil }
        for case .object(let widget) in widgets {
            if case .string(type)? = widget["wmType"] { return widget }
        }
        return nil
    }

    /// Widgets of a type that can have several instances (stash search).
    public func widgets(_ type: String) -> [[String: JSONValue]] {
        guard case .array(let widgets)? = root["widgets"] else { return [] }
        return widgets.compactMap { value in
            guard case .object(let widget) = value, case .string(type)? = widget["wmType"] else { return nil }
            return widget
        }
    }

    /// Changes the first widget of `type` (or the one with `wmId`).
    public mutating func updateWidget(_ type: String, id: Double? = nil, _ change: (inout [String: JSONValue]) -> Void) {
        guard case .array(var widgets)? = root["widgets"] else { return }
        for index in widgets.indices {
            guard case .object(var widget) = widgets[index], case .string(type)? = widget["wmType"] else { continue }
            if let id, case .number(let wmId)? = widget["wmId"], wmId != id { continue }
            change(&widget)
            widgets[index] = .object(widget)
            root["widgets"] = .array(widgets)
            return
        }
    }

    /// Show a notice over the game when it's found (Exiled Exchange 2's General setting, on by default).
    public var showAttachNotification: Bool {
        get { Self.bool(root["showAttachNotification"], default: true) }
        set { root["showAttachNotification"] = .bool(newValue) }
    }

    // MARK: Chat commands

    public struct Command: Equatable, Sendable, Identifiable {
        public var id = UUID()
        public var text: String
        public var hotkey: String?
        public var send: Bool

        public init(text: String, hotkey: String?, send: Bool) {
            self.text = text
            self.hotkey = hotkey
            self.send = send
        }

        public static func == (a: Command, b: Command) -> Bool {
            a.text == b.text && a.hotkey == b.hotkey && a.send == b.send
        }
    }

    public var commands: [Command] {
        get {
            guard case .array(let list)? = root["commands"] else { return [] }
            return list.compactMap { value in
                guard case .object(let command) = value, case .string(let text)? = command["text"] else { return nil }
                return Command(text: text, hotkey: Self.string(command["hotkey"]), send: Self.bool(command["send"]))
            }
        }
        set {
            root["commands"] = .array(newValue.map { command in
                .object(["text": .string(command.text), "hotkey": command.hotkey.map(JSONValue.string) ?? .null,
                         "send": .bool(command.send)])
            })
        }
    }

    // MARK: Stash search

    public struct StashSearchEntry: Equatable, Sendable, Identifiable {
        public var id: Double
        public var name: String
        public var text: String
        public var hotkey: String?

        public init(id: Double, name: String, text: String, hotkey: String?) {
            self.id = id
            self.name = name
            self.text = text
            self.hotkey = hotkey
        }
    }

    /// Entries of the first stash search widget (upstream can have several; each keeps its own).
    public func stashSearchEntries(widgetID: Double) -> [StashSearchEntry] {
        guard let widget = widgets("stash-search").first(where: { Self.number($0["wmId"]) == widgetID }),
              case .array(let entries)? = widget["entries"] else { return [] }
        return entries.compactMap { value in
            guard case .object(let entry) = value else { return nil }
            return StashSearchEntry(id: Self.number(entry["id"]) ?? 0, name: Self.string(entry["name"]) ?? "",
                                    text: Self.string(entry["text"]) ?? "", hotkey: Self.string(entry["hotkey"]))
        }
    }

    public mutating func setStashSearchEntries(_ entries: [StashSearchEntry], widgetID: Double) {
        updateWidget("stash-search", id: widgetID) { widget in
            widget["entries"] = .array(entries.map { entry in
                .object(["id": .number(entry.id), "name": .string(entry.name), "text": .string(entry.text),
                         "hotkey": entry.hotkey.map(JSONValue.string) ?? .null])
            })
        }
    }

    // MARK: Host config (port of Config.ts `getConfigForHost`)

    /// The same `HostConfig` the overlay would send, computed from the file. SwiftExile uses it when
    /// settings change in the native window, without waiting for the web overlay.
    /// What each hotkey does, in words ("Price check", "Chat command “/hideout”"…), for telling the
    /// user a hotkey is already taken.
    public func hotkeyUses() -> [String: [String]] {
        var uses: [String: [String]] = [:]
        for case .object(let entry) in hostConfig().shortcuts {
            guard let shortcut = Self.string(entry["shortcut"]), case .object(let action)? = entry["action"] else { continue }
            uses[shortcut, default: []].append(Self.describe(action))
        }
        return uses
    }

    static func describe(_ action: [String: JSONValue]) -> String {
        let target = string(action["target"]) ?? ""
        switch string(action["type"]) {
        case "copy-item":
            switch target {
            case "price-check": return bool(action["focusOverlay"], default: false) ? "Price check (without auto-hide)" : "Price check"
            case "item-check": return "Item check"
            case "open-wiki": return "Open on the wiki"
            case "open-poedb": return "Open on poe2db"
            case "open-craft-of-exile": return "Open on Craft of Exile"
            case "search-similar": return "Find in stash"
            case "search-same-priced": return "Find same price in stash"
            case "log-item": return "Library: log item"
            default: return target
            }
        case "toggle-overlay": return "Overlay"
        case "paste-in-chat": return "Chat command “\(string(action["text"]) ?? "")”"
        case "stash-search": return "Stash search “\(string(action["text"]) ?? "")”"
        case "ocr-text": return "Heist gems"
        case "trigger-event": return target.hasPrefix("stopwatch") ? "Stopwatch" : "Delve grid"
        default: return string(action["type"]) ?? "Another action"
        }
    }

    public func hostConfig() -> HostConfig {
        var actions: [JSONValue] = []
        func add(_ shortcut: String?, _ action: [String: JSONValue], keepModKeys: Bool = false) {
            guard let shortcut, !shortcut.isEmpty else { return }
            var entry: [String: JSONValue] = ["shortcut": .string(shortcut), "action": .object(action)]
            if keepModKeys { entry["keepModKeys"] = .bool(true) }
            actions.append(.object(entry))
        }
        func copyItem(_ target: String, focus: Bool? = nil) -> [String: JSONValue] {
            var action: [String: JSONValue] = ["type": .string("copy-item"), "target": .string(target)]
            if let focus { action["focusOverlay"] = .bool(focus) }
            return action
        }

        let priceCheck = widget("price-check") ?? [:]
        if let key = Self.string(priceCheck["hotkey"]) {
            let hold = Self.string(priceCheck["hotkeyHold"]) ?? "Alt"
            add("\(hold) + \(key)", copyItem("price-check", focus: false), keepModKeys: true)
        }
        add(Self.string(priceCheck["hotkeyLocked"]), copyItem("price-check", focus: true))
        add(self[string: "overlayKey"] ?? "Shift + Space", ["type": .string("toggle-overlay")])

        let itemCheck = widget("item-check") ?? [:]
        add(Self.string(itemCheck["wikiKey"]), copyItem("open-wiki"))
        add(Self.string(itemCheck["craftOfExileKey"]), copyItem("open-craft-of-exile"))
        add(Self.string(itemCheck["poedbKey"]), copyItem("open-poedb"))
        add(Self.string(itemCheck["stashSearchKey"]), copyItem("search-similar"))
        add(Self.string(itemCheck["samePricedKey"]), copyItem("search-same-priced"))
        add(Self.string(itemCheck["hotkey"]), copyItem("item-check", focus: true))

        let library = widget("library") ?? [:]
        add(Self.string(library["logItemKey"]), copyItem("log-item"), keepModKeys: true)

        let delveGrid = widget("delve-grid") ?? [:]
        add(Self.string(delveGrid["toggleKey"]), ["type": .string("trigger-event"), "target": .string("delve-grid")], keepModKeys: true)

        for command in commands {
            add(command.hotkey, ["type": .string("paste-in-chat"), "text": .string(command.text), "send": .bool(command.send)])
        }

        guard case .array(let widgets)? = root["widgets"] else { return HostConfig() }
        for case .object(let widget) in widgets {
            switch Self.string(widget["wmType"]) {
            case "stash-search":
                guard Self.bool(widget["enableHotkeys"], default: true), case .array(let entries)? = widget["entries"] else { continue }
                for case .object(let entry) in entries {
                    add(Self.string(entry["hotkey"]), ["type": .string("stash-search"), "text": .string(Self.string(entry["text"]) ?? "")])
                }
            case "timer":
                let id = Self.number(widget["wmId"]).map { String(Int($0)) } ?? "0"
                add(Self.string(widget["toggleKey"]), ["type": .string("trigger-event"), "target": .string("stopwatch-start-stop:\(id)")], keepModKeys: true)
                add(Self.string(widget["resetKey"]), ["type": .string("trigger-event"), "target": .string("stopwatch-reset:\(id)")], keepModKeys: true)
            case "item-search":
                add(Self.string(widget["ocrGemsKey"]), ["type": .string("ocr-text"), "target": .string("heist-gems")], keepModKeys: true)
            default:
                continue
            }
        }

        let alphas: [String] = {
            guard case .array(let list)? = root["alphas"] else { return [] }
            return list.compactMap { if case .string(let alpha) = $0 { return alpha }; return nil }
        }()
        let host: [String: JSONValue] = [
            "shortcuts": .array(actions),
            "restoreClipboard": .bool(self[bool: "restoreClipboard"]),
            "clientLog": root["clientLog"] ?? .null,
            "gameConfig": root["gameConfig"] ?? .null,
            "stashScroll": .bool(self[bool: "stashScroll"]),
            "overlayKey": .string(self[string: "overlayKey"] ?? "Shift + Space"),
            "logKeys": .bool(self[bool: "logKeys"]),
            "windowTitle": .string(self[string: "windowTitle"] ?? "Path of Exile 2"),
            "language": .string(self[string: "language"] ?? "en"),
            "readClientLog": .bool(self[bool: "readClientLog"]),
            "libraryAlpha": .bool(self[bool: "enableAlphas"] && alphas.contains("library")),
            "libraryOutputPath": library["libraryOutputPath"] ?? .null,
            "initialDelay": priceCheck["initialDelay"] ?? .number(48),
            "hideOverlayOnBlur": .bool(self[bool: "hideOverlayOnBlur"]),
        ]
        return (try? JSONValue.object(host).decode(HostConfig.self)) ?? HostConfig()
    }

    // MARK: Helpers

    public static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value, !text.isEmpty { return text }
        return nil
    }

    public static func bool(_ value: JSONValue?, default fallback: Bool = false) -> Bool {
        if case .bool(let flag)? = value { return flag }
        return fallback
    }

    public static func number(_ value: JSONValue?) -> Double? {
        if case .number(let number)? = value { return number }
        return nil
    }
}
