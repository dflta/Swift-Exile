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
    private(set) var stats: [StatFilter] = []
    private(set) var api = "trade"
    private(set) var results: SearchResults?
    private(set) var isSearching = false
    private(set) var searchError: String?

    private let engine: PriceCheckEngine
    private let log: (String) -> Void
    /// Increases with every new item, so results for an older item are dropped.
    private var generation = 0

    init(engine: PriceCheckEngine, log: @escaping (String) -> Void) {
        self.engine = engine
        self.log = log
    }

    func show(clipboard: String, advanced: Bool) async {
        generation += 1
        let current = generation
        phase = .checking
        check = nil
        stats = []
        results = nil
        searchError = nil
        do {
            let started = Date()
            let result = try await engine.check(clipboard: clipboard, advanced: advanced)
            guard current == generation else { return }
            check = result
            stats = result.stats
            api = result.api
            phase = .ready
            log("debug [PriceCheck] \(result.item.name): \(result.stats.count) filters, \(result.api) search, parsed in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            if result.searchByDefault { await search() }
        } catch {
            guard current == generation else { return }
            phase = .failed(Self.message(for: error))
            log("warn [PriceCheck] \(error)")
        }
    }

    func setEnabled(_ stat: StatFilter, _ enabled: Bool) async {
        await update(stat, disabled: !enabled, min: stat.roll?.min, max: stat.roll?.max)
    }

    func setMinimum(_ stat: StatFilter, _ value: Double?) async {
        await update(stat, disabled: stat.disabled, min: value, max: stat.roll?.max)
    }

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

    private func update(_ stat: StatFilter, disabled: Bool, min: Double?, max: Double?) async {
        do {
            let updated = try await engine.setStat(index: stat.index, disabled: disabled, min: min, max: max)
            stats = updated.stats
            api = updated.api
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
