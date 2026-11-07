import Foundation
import SwiftExileCore
import WebKit

/// Runs Exiled Exchange 2's price-check logic (Engine/engine.ts) in a hidden web view and returns
/// typed results for the native SwiftUI price check.
@MainActor
final class PriceCheckEngine: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    enum Failure: Error, CustomStringConvertible {
        case notReady, unexpectedResult, loadFailed(String)
        var description: String {
            switch self {
            case .notReady: return "price-check engine is not ready"
            case .unexpectedResult: return "unexpected result from the price-check engine"
            case .loadFailed(let reason): return "price-check engine failed to load: \(reason)"
            }
        }
    }

    private let webView: WKWebView
    private let pageURL: URL
    private let log: (String) -> Void
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var startTask: Task<EngineInfo, Error>?

    init(serverPort: Int, log: @escaping (String) -> Void) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Not in any window: keep JavaScript timers and network running while hidden.
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.addEventListener('error', e => window.webkit.messageHandlers.engineLog.postMessage(`${e.message} @ ${e.filename}:${e.lineno}`));"
                + "window.addEventListener('unhandledrejection', e => window.webkit.messageHandlers.engineLog.postMessage('unhandledrejection: ' + ((e.reason && e.reason.stack) || e.reason)));",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        pageURL = URL(string: "http://localhost:\(serverPort)/engine/index.html")!
        self.log = log
        super.init()
        configuration.userContentController.add(self, name: "engineLog")
        webView.navigationDelegate = self
    }

    /// Loads the engine page and runs `init()` once; later calls wait for the same start.
    @discardableResult
    func start() async throws -> EngineInfo {
        if let startTask { return try await startTask.value }
        let task = Task { () throws -> EngineInfo in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loadContinuation = continuation
                webView.load(URLRequest(url: pageURL))
            }
            let info = try await call(EngineInfo.self, "return await SwiftExileEngine.init()")
            let currency = UserDefaults.standard.string(forKey: PriceCurrency.defaultsKey) ?? PriceCurrency.auto.rawValue
            _ = try? await call([String: String].self, "return await SwiftExileEngine.setPriceCurrency(mode)", ["mode": currency])
            log("info [PriceCheck] engine ready (\(info.language), league \(info.league ?? "none"))")
            return info
        }
        startTask = task
        do {
            return try await task.value
        } catch {
            startTask = nil // allow a retry
            throw error
        }
    }

    func check(clipboard: String, advanced: Bool) async throws -> PriceCheck {
        try await start()
        return try await call(PriceCheck.self, "return await SwiftExileEngine.check(text, advanced)",
                              ["text": clipboard, "advanced": advanced])
    }

    /// The native item check's data for copied item text.
    func itemInfo(clipboard: String) async throws -> ItemCheckResult {
        try await start()
        return try await call(ItemCheckResult.self, "return SwiftExileEngine.itemInfo(text)", ["text": clipboard])
    }

    /// Every map modifier to rate in the map check settings.
    func mapModifiers() async throws -> [MapModifier] {
        try await start()
        return try await call([MapModifier].self, "return SwiftExileEngine.mapModifiers()")
    }

    func setStat(index: Int, disabled: Bool, min: Double?, max: Double?) async throws -> FilterState {
        try await call(FilterState.self, "return SwiftExileEngine.setStat(index, disabled, min, max)",
                       ["index": index, "disabled": disabled, "min": Self.orNull(min), "max": Self.orNull(max)])
    }

    func setItemFilter(key: String, disabled: Bool, value: Double?, max: Double?) async throws -> FilterState {
        try await call(FilterState.self, "return SwiftExileEngine.setItemFilter(key, disabled, value, max)",
                       ["key": key, "disabled": disabled, "value": Self.orNull(value), "max": Self.orNull(max)])
    }

    /// `key`: "listingType", "listed", or "currency"; nil value = any.
    func setTradeOption(key: String, value: String?) async throws -> FilterState {
        try await call(FilterState.self, "return SwiftExileEngine.setTradeOption(key, value)",
                       ["key": key, "value": Self.orNull(value)])
    }

    func setAugment(index: Int, refName: String?) async throws -> EditResult {
        try await call(EditResult.self, "return SwiftExileEngine.setAugment(index, refName)",
                       ["index": index, "refName": Self.orNull(refName)])
    }

    func setCatalyst(refName: String, quality: Int) async throws -> EditResult {
        try await call(EditResult.self, "return SwiftExileEngine.setCatalyst(refName, quality)",
                       ["refName": refName, "quality": quality])
    }

    /// poe.ninja price for `count` items.
    func ninja(count: Int) async throws -> NinjaPrice? {
        struct Reply: Decodable { var ninja: NinjaPrice? }
        return try await call(Reply.self, "return await SwiftExileEngine.ninjaFor(count)", ["count": count]).ninja
    }

    func setPriceCurrency(_ currency: PriceCurrency) async throws {
        try await start()
        _ = try await call([String: String].self, "return await SwiftExileEngine.setPriceCurrency(mode)", ["mode": currency.rawValue])
    }

    func setLeague(id: String) async throws {
        _ = try await call([String: String].self, "return SwiftExileEngine.setLeague(id)", ["id": id])
    }

    func selectPreset(id: String) async throws -> FilterState {
        try await call(FilterState.self, "return SwiftExileEngine.selectPreset(id)", ["id": id])
    }

    /// Trade site URL for the current search; `have` picks the currency for bulk exchange links.
    /// - Parameter account: limit the search to one seller (their listing of this item).
    func tradeLink(have: String?, account: String? = nil) async throws -> TradeLink {
        try await call(TradeLink.self, "return SwiftExileEngine.tradeLink(have, account)",
                       ["have": Self.orNull(have), "account": Self.orNull(account)])
    }

    private static func orNull<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

    func search() async throws -> SearchResults {
        try await call(SearchResults.self, "return await SwiftExileEngine.search()")
    }

    private func call<T: Decodable>(_ type: T.Type, _ body: String, _ arguments: [String: Any] = [:]) async throws -> T {
        let result = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        guard let text = result as? String else { throw Failure.unexpectedResult }
        return try EngineJSON.decode(T.self, from: text)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: Failure.loadFailed(error.localizedDescription))
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: Failure.loadFailed(error.localizedDescription))
        loadContinuation = nil
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let text = message.body as? String {
            log("error [PriceCheck] engine: \(text)")
        }
    }
}
