import AppKit
import SwiftExileCore
import SwiftUI

/// What the native item check shows.
@MainActor
@Observable
final class ItemCheckModel {
    enum Phase: Equatable {
        case idle
        case ready(ItemCheck)
        case map(MapCheck)
        case failed(String)
    }

    var phase: Phase = .idle
    /// The copied item text, for "Price check".
    var clipboard = ""
    /// Exiled Exchange 2's settings, where the map check's modifier ratings live.
    var settings: OverlaySettingsStore?
}

/// The native item check (Exiled Exchange 2's item info: wiki and poe2db links, stash searches,
/// weapon DPS), with the item's modifiers and tiers, and the map check for waystones, tablets, and
/// contracts. Opens next to the game's stash or inventory panel, like the price check.
@MainActor
final class ItemCheckController {
    static let width: CGFloat = 400
    static let maxHeight: CGFloat = 760

    let model = ItemCheckModel()
    private let engine: PriceCheckEngine
    private let panel = PriceCheckPanel()
    private var anchorTop: CGPoint? { didSet { sizer?.anchorTop = anchorTop } }
    private var sizer: TopAnchoredSizer!
    private var activationObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var cursor: CGPoint = .zero
    /// Hidden while another app is in front, to come back with the game ("restore the overlay when
    /// you return").
    private var suspended = false

    /// Whether a process is the game (set by the app delegate).
    var isGame: (pid_t) -> Bool = { _ in false }
    var overlayWindowNumber: () -> Int = { 0 }
    /// Buttons: run a stash search in the game, and open the price check for this item.
    var onStashSearch: (String) -> Void = { _ in }
    var onPriceCheck: (_ clipboard: String, _ cursor: CGPoint) -> Void = { _, _ in }

    init(engine: PriceCheckEngine) {
        self.engine = engine
        let hosting = NSHostingController(rootView: ItemCheckView(model: model, actions: .init()))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.rootView = ItemCheckView(model: model, actions: .init(
            close: { [weak self] in self?.hide() },
            moved: { [weak self] in self?.movedByUser() },
            open: { url in NSWorkspace.shared.open(url) },
            stashSearch: { [weak self] text in
                guard let self else { return }
                self.hide()
                self.onStashSearch(text)
            },
            priceCheck: { [weak self] in
                guard let self else { return }
                let text = self.model.clipboard
                self.hide()
                self.onPriceCheck(text, self.cursor)
            }))
        sizer = TopAnchoredSizer(panel: panel, hosting: hosting)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                guard let self, pid != getpid() else { return }
                if self.isGame(pid) {
                    if self.suspended {
                        self.suspended = false
                        self.panel.orderFrontRegardless()
                    }
                    return
                }
                guard self.panel.isVisible else { return }
                if UserDefaults.standard.bool(forKey: OverlayController.restoreOnReturnKey) {
                    self.suspended = true
                    self.panel.orderOut(nil)
                } else {
                    self.hide() // another app came to the front
                }
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53
            let isOurs = MainActor.assumeIsolated { event.window === self?.panel }
            guard isEscape, isOurs else { return event }
            MainActor.assumeIsolated { self?.hide() }
            return nil
        }
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }

    /// Reads the item and shows it. Returns false when Exiled Exchange 2 should show it instead (text
    /// the parser doesn't understand).
    /// - Parameters:
    ///   - cursor: where the item was, Quartz coordinates.
    ///   - game: the game's drawable area, Quartz coordinates.
    func show(clipboard: String, cursor: CGPoint, game: CGRect) async -> Bool {
        let result: ItemCheckResult
        do {
            result = try await engine.itemInfo(clipboard: clipboard)
        } catch {
            return false
        }
        model.clipboard = clipboard
        switch result {
        case .item(let check): model.phase = .ready(check)
        case .map(let map): model.phase = .map(map)
        }
        self.cursor = cursor
        let frame = PriceCheckPlacement.frame(game: game, cursorX: cursor.x, size: CGSize(width: Self.width, height: Self.maxHeight))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = ScreenCoordinates.cocoaRect(fromQuartz: frame, primaryHeight: primaryHeight)
        anchorTop = CGPoint(x: cocoa.minX, y: cocoa.maxY)
        panel.setFrameTopLeftPoint(anchorTop!)
        sizer.apply()
        suspended = false
        panel.orderFrontRegardless()
        panel.makeKey()
        return true
    }

    func hide() {
        suspended = false
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Hands keyboard focus back to the game (before a hotkey's copy chord), keeping the panel.
    func releaseFocus(toGame pid: pid_t?) {
        guard panel.isKeyWindow || NSApp.isActive else { return }
        NSApp.deactivate()
        if let pid, let game = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: game)
            game.activate(from: .current, options: [])
        }
    }

    /// A click anywhere (Quartz coordinates): outside the panel and its menus closes it.
    func mouseDown(atQuartz point: CGPoint) {
        guard panel.isVisible else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = CGPoint(x: point.x, y: primaryHeight - point.y)
        if panel.frame.contains(cocoa) || isOwnPopup(at: cocoa) { return }
        hide()
    }

    /// Renders the panel's content to a PNG (development checks).
    func snapshot(to url: URL) -> Bool {
        guard let view = panel.contentView, view.bounds.width > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    private func isOwnPopup(at cocoa: CGPoint) -> Bool {
        let number = NSWindow.windowNumber(at: cocoa, belowWindowWithWindowNumber: 0)
        guard number > 0, number != overlayWindowNumber(),
              let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
              let owner = info.first?[kCGWindowOwnerPID as String] as? pid_t
        else { return false }
        return owner == getpid()
    }

    private func movedByUser() {
        anchorTop = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }
}

// MARK: View

struct ItemCheckView: View {
    struct Actions {
        var close: () -> Void = {}
        var moved: () -> Void = {}
        var open: (URL) -> Void = { _ in }
        var stashSearch: (String) -> Void = { _ in }
        var priceCheck: () -> Void = {}
    }

    let model: ItemCheckModel
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .ready(let check) = model.phase {
                header(check)
                Divider()
                ScrollView {
                    content(check)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: ItemCheckController.maxHeight - 120)
                .fixedSize(horizontal: false, vertical: true)
            } else if case .map(let map) = model.phase {
                MapCheckView(map: map, store: model.settings, close: actions.close, moved: actions.moved)
            } else {
                Text("Reading item…").foregroundStyle(.secondary).padding(14)
            }
        }
        .frame(width: ItemCheckController.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private func header(_ check: ItemCheck) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if !check.item.icon.isEmpty { RemoteIcon(url: check.item.icon, size: 36) }
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title ?? check.item.name)
                    .font(.headline)
                    .foregroundStyle(ItemColors.rarity(check.item.rarity))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if check.title != nil { Text(check.item.name).foregroundStyle(.primary.opacity(0.8)).fixedSize() }
                    if let category = check.item.category { Text(category).truncationMode(.tail) }
                    Group {
                        if let level = check.item.itemLevel { Text("ilvl \(level)") }
                        if let quality = check.item.quality, quality > 0 { Text("+\(quality)%") }
                        if check.item.corrupted { Text("Corrupted").foregroundStyle(.red) }
                        if check.mirrored { Text("Mirrored") }
                        if check.sanctified { Text("Sanctified") }
                        if check.item.unidentified { Text("Unidentified") }
                    }
                    .fixedSize()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Button(action: actions.close) {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close (Esc)")
        }
        .padding(14)
        .dragsWindow(onEnded: actions.moved)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ check: ItemCheck) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            actionsRow(check)
            if check.weapon != nil || check.defences != nil || check.requires != nil || !(check.skills ?? []).isEmpty {
                properties(check)
            }
            if !check.mods.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(check.mods.enumerated()), id: \.offset) { _, mod in
                        ModifierRow(mod: mod)
                    }
                }
            } else if check.known != false, check.item.rarity == "Rare" || check.item.rarity == "Magic" {
                Text("Modifier tiers appear when the item is copied with advanced descriptions (the game's Alt key).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = check.note {
                Label(note, systemImage: "tag").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func actionsRow(_ check: ItemCheck) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                linkButton("Wiki", check.links.wiki)
                if let poedb = check.links.poedb { linkButton("poe2db", poedb) }
                if let coe = check.links.craftOfExile { linkButton("Craft of Exile", coe) }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Button {
                    actions.stashSearch(check.stashSearch)
                } label: {
                    Label("Find in stash", systemImage: "magnifyingglass")
                }
                .help("Search the open stash in the game for this item")
                if let samePriced = check.samePricedSearch {
                    Button {
                        actions.stashSearch(samePriced)
                    } label: {
                        Label("Same price note", systemImage: "tag")
                    }
                    .help("Search the open stash for items with the same price note (\(check.note ?? ""))")
                }
                Spacer(minLength: 0)
                if check.known != false {
                    Button(action: actions.priceCheck) {
                        Label("Price check", systemImage: "dollarsign.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .controlSize(.regular)
    }

    private func linkButton(_ title: String, _ link: String) -> some View {
        Button {
            if let url = URL(string: link) { actions.open(url) }
        } label: {
            Label(title, systemImage: "arrow.up.right.square")
        }
        .help(link)
    }

    private func properties(_ check: ItemCheck) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            if let weapon = check.weapon {
                if let physical = weapon.physicalDps, physical > 0 { row("Physical DPS", "\(physical)") }
                if let elemental = weapon.elementalDps, elemental > 0 { row("Elemental DPS", "\(elemental)") }
                row("Total DPS", "\(weapon.totalDps)", bold: true)
                row("Attacks per second", weapon.attacksPerSecond.formatted(.number.precision(.fractionLength(0...2))))
                if let crit = weapon.critChance { row("Critical hit chance", crit.formatted(.number.precision(.fractionLength(0...2))) + "%") }
            }
            if let defences = check.defences {
                if let value = defences.armour, value > 0 { row("Armour", "\(value)") }
                if let value = defences.evasion, value > 0 { row("Evasion", "\(value)") }
                if let value = defences.energyShield, value > 0 { row("Energy Shield", "\(value)") }
                if let value = defences.ward, value > 0 { row("Ward", "\(value)") }
                if let value = defences.block, value > 0 { row("Block", "\(value)%") }
            }
            ForEach(Array((check.skills ?? []).enumerated()), id: \.offset) { _, skill in
                row("Grants skill", skill, bold: true)
            }
            if let requires = check.requires {
                row("Requires", requirementText(requires))
            }
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String, bold: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fontWeight(bold ? .semibold : .regular)
        }
    }

    private func requirementText(_ requires: ItemCheck.Requirements) -> String {
        var parts = ["Level \(requires.level)"]
        if requires.str > 0 { parts.append("\(requires.str) Str") }
        if requires.dex > 0 { parts.append("\(requires.dex) Dex") }
        if requires.int > 0 { parts.append("\(requires.int) Int") }
        return parts.joined(separator: ", ")
    }
}

/// One modifier: its kind and tier, its name, and its lines with the roll ranges dimmed.
private struct ModifierRow: View {
    let mod: ItemCheck.Modifier

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !badge.isEmpty {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tierColor)
                    .frame(width: 34, alignment: .leading)
                    .help(kindDescription)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(mod.lines.enumerated()), id: \.offset) { _, line in
                    lineText(line).font(.callout)
                }
                if let name = mod.name, !name.isEmpty {
                    Text(name).font(.caption).italic().foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// "P1", "S8", "Imp", "Rune"… (prefix or suffix and tier).
    private var badge: String {
        let tier = mod.tier.map(String.init) ?? ""
        switch mod.generation {
        case "prefix": return "P\(tier)"
        case "suffix": return "S\(tier)"
        default: break
        }
        switch mod.type {
        case "implicit": return "Imp"
        case "rune", "added-rune": return "Rune"
        case "enchant": return "Ench"
        case "skill": return "Skill"
        case "fractured": return "Frac"
        case "desecrated": return "Des"
        default: return tier.isEmpty ? "" : "T\(tier)"
        }
    }

    private var kindDescription: String {
        var parts: [String] = []
        if let generation = mod.generation { parts.append(generation.capitalized) }
        parts.append(mod.type.capitalized + " modifier")
        if let tier = mod.tier { parts.append("tier \(tier)") }
        if !mod.tags.isEmpty { parts.append(mod.tags.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private var tierColor: Color {
        switch mod.tier {
        case 1: return Color(red: 1.0, green: 0.75, blue: 0.3)
        case 2: return Color(red: 0.55, green: 0.85, blue: 0.55)
        default: return .secondary
        }
    }

    private func lineText(_ line: String) -> Text {
        ModLineText.segments(line).reduce(Text("")) { text, segment in
            text + Text(segment.text).foregroundColor(segment.isRange ? Color.secondary.opacity(0.7) : modColor)
        }
    }

    private var modColor: Color {
        switch mod.type {
        case "rune", "added-rune", "enchant": return Color(red: 0.6, green: 0.8, blue: 1.0)
        case "fractured": return Color(red: 0.75, green: 0.68, blue: 0.5)
        case "desecrated": return Color(red: 0.8, green: 0.6, blue: 0.9)
        default: return Color(red: 0.6, green: 0.6, blue: 1.0)
        }
    }
}
