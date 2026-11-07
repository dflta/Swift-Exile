import AppKit
import Foundation
import Observation
import SwiftExileCore

/// State of the native price check, backed by the headless engine.
@MainActor
@Observable
final class PriceCheckModel {
    enum Phase: Equatable {
        case idle
        case checking
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var check: PriceCheck?
    /// Current filters (changes after every edit; `check.filters` keeps the initial ones).
    private(set) var filters: FilterState?
    /// poe.ninja price, refreshed when the Stock amount changes.
    private(set) var ninja: NinjaPrice?
    /// Rune / catalyst editor for this item.
    private(set) var editor: ItemEditorState?
    /// Small currency icons for menus (AppKit menus can't load remote images themselves).
    private(set) var menuIcons: [String: NSImage] = [:]
    private(set) var results: SearchResults?
    private(set) var isSearching = false
    private(set) var searchError: String?
    /// Pinned: stays open on clicks outside and comes back with the game (upstream's pin).
    var isPinned = false

    var api: String { filters?.api ?? "trade" }
    var stats: [StatFilter] { filters?.stats ?? [] }

    private let engine: PriceCheckEngine
    private let log: (String) -> Void
    /// Increases with every new item, so results for an older item are dropped.
    private var generation = 0
    /// The item shown, to check it again in another league.
    private var lastItem: (clipboard: String, advanced: Bool)?

    init(engine: PriceCheckEngine, log: @escaping (String) -> Void) {
        self.engine = engine
        self.log = log
    }

    func show(clipboard: String, advanced: Bool) async {
        lastItem = (clipboard, advanced)
        generation += 1
        let current = generation
        phase = .checking
        check = nil
        filters = nil
        ninja = nil
        editor = nil
        results = nil
        searchError = nil
        do {
            let started = Date()
            let result = try await engine.check(clipboard: clipboard, advanced: advanced)
            guard current == generation else { return }
            check = result
            filters = result.filters
            ninja = result.ninja
            editor = result.editor
            loadMenuIcons(result.currencyIcons)
            phase = .ready
            log("debug [PriceCheck] \(result.item.name): \(result.filters.stats.count) filters, \(result.filters.api) search, parsed in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            if result.searchByDefault { await search() }
        } catch {
            guard current == generation else { return }
            phase = .failed(Self.message(for: error))
            log("warn [PriceCheck] \(error)")
        }
    }

    // MARK: Filters

    func setEnabled(_ stat: StatFilter, _ enabled: Bool) async {
        await apply { try await $0.setStat(index: stat.index, disabled: !enabled, min: stat.roll?.min, max: stat.roll?.max) }
    }

    /// Changing a range also turns the filter on, like upstream's min/max inputs.
    func setRange(_ stat: StatFilter, min: Double?, max: Double?) async {
        await apply { try await $0.setStat(index: stat.index, disabled: false, min: min, max: max) }
    }

    func setEnabled(_ chip: ItemFilterChip, _ enabled: Bool) async {
        await apply { try await $0.setItemFilter(key: chip.key, disabled: !enabled, value: chip.value, max: chip.max) }
    }

    func setValue(_ chip: ItemFilterChip, _ value: Double) async {
        await apply { try await $0.setItemFilter(key: chip.key, disabled: false, value: value, max: chip.max) }
        // The stock amount also sets how many items the poe.ninja total is for.
        if chip.key == "stackSize", ninja?.stack != nil || (check?.item.stackSize ?? 1) > 1 {
            let current = generation
            if let updated = try? await engine.ninja(count: Int(value)), current == generation { ninja = updated }
        }
    }

    /// Shows poe.ninja prices in another currency (Settings ▸ Price Check).
    func setPriceCurrency(_ currency: PriceCurrency) async {
        do {
            try await engine.setPriceCurrency(currency)
            guard check != nil else { return }
            let count = filters?.itemFilters.first { $0.key == "stackSize" }?.value.map(Int.init) ?? check?.item.stackSize ?? 1
            let current = generation
            if let updated = try await engine.ninja(count: count), current == generation { ninja = updated }
        } catch {
            log("warn [PriceCheck] price currency: \(error)")
        }
    }

    private func loadMenuIcons(_ urls: [String: String]) {
        for (id, link) in urls where menuIcons[id] == nil {
            guard let url = URL(string: link) else { continue }
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
                image.size = NSSize(width: 16, height: 16)
                menuIcons[id] = image
            }
        }
    }

    // MARK: Item editor

    func setAugment(socket: Int, _ refName: String?) async {
        await applyEdit { try await $0.setAugment(index: socket, refName: refName) }
    }

    func setCatalyst(_ refName: String, quality: Int) async {
        await applyEdit { try await $0.setCatalyst(refName: refName, quality: quality) }
    }

    private func applyEdit(_ change: (PriceCheckEngine) async throws -> EditResult) async {
        let current = generation
        do {
            let result = try await change(engine)
            guard current == generation else { return }
            filters = result.filters
            editor = result.editor
            results = nil
        } catch {
            searchError = Self.message(for: error)
        }
    }

    /// Search any item of the category ("Any Gloves") instead of the exact name.
    func setRelaxed(_ relaxed: Bool) async {
        await apply { try await $0.setItemFilter(key: "searchRelaxed", disabled: !relaxed, value: nil, max: nil) }
    }

    func setTradeOption(_ key: String, _ value: String?) async {
        await apply { try await $0.setTradeOption(key: key, value: value) }
    }

    /// Switches the trade league for this session and prices the item again.
    func selectLeague(_ id: String) async {
        guard id != check?.league, let lastItem else { return }
        do {
            try await engine.setLeague(id: id)
            log("info [PriceCheck] league switched to \(id)")
            await show(clipboard: lastItem.clipboard, advanced: lastItem.advanced)
        } catch {
            searchError = Self.message(for: error)
        }
    }

    func selectPreset(_ id: String) async {
        await apply { try await $0.selectPreset(id: id) }
    }

    // MARK: Search

    func search() async {
        let current = generation
        isSearching = true
        searchError = nil
        defer { if current == generation { isSearching = false } }
        do {
            let found = try await engine.search()
            guard current == generation else { return }
            results = found
        } catch {
            guard current == generation else { return }
            searchError = Self.message(for: error)
            log("warn [PriceCheck] search failed: \(error)")
        }
    }

    /// Opens the same search on the trade site in the default browser.
    func openTradeSite(have: String? = nil, account: String? = nil) async {
        do {
            let link = try await engine.tradeLink(have: have, account: account)
            guard let url = URL(string: link.url) else { return }
            NSWorkspace.shared.open(url)
        } catch {
            searchError = Self.message(for: error)
        }
    }

    func open(_ link: String?) {
        guard let link, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    private func apply(_ change: (PriceCheckEngine) async throws -> FilterState) async {
        let current = generation
        do {
            let updated = try await change(engine)
            guard current == generation else { return }
            filters = updated
            results = nil // filters changed: old results no longer match
        } catch {
            searchError = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        if let engineError = error as? EngineError {
            switch engineError.error {
            case "item.unknown", "UNKNOWN_ITEM": return "This item can't be price checked."
            default: return engineError.error
            }
        }
        return String(describing: error)
    }
}
