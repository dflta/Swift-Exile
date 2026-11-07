import AppKit
import WebKit

/// Owns the WKWebView that runs the upstream renderer (plan §2.5).
@MainActor
final class WebViewHost: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView

    init(userAgentSuffix: String, transparent: Bool) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = userAgentSuffix
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.consoleBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.paintTimer, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "console")
        configuration.userContentController.add(self, name: "latency")
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isInspectable = true // Safari ▸ Develop menu, like Electron's toggleDevTools
        if transparent {
            // No public API for a transparent WKWebView on macOS; this KVC key is widely used (risk R7).
            webView.setValue(false, forKey: "drawsBackground")
            webView.underPageBackgroundColor = .clear
        }
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func evaluate(_ script: String) {
        webView.evaluateJavaScript(script) { result, error in
            print("[eval] \(error.map { "error: \($0.localizedDescription)" } ?? String(describing: result ?? "nil"))")
        }
    }

    @objc func reloadPage(_ sender: Any?) {
        webView.reload()
    }

    func snapshot(to url: URL) {
        webView.takeSnapshot(with: nil) { image, error in
            guard let image, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else {
                print("[snapshot] failed: \(error?.localizedDescription ?? "no image")")
                return
            }
            do {
                try png.write(to: url)
                print("[snapshot] saved \(url.path)")
            } catch {
                print("[snapshot] failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: External links (parity with setWindowOpenHandler → shell.openExternal, OverlayWindow.ts:71-74)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame == true,
              let url = navigationAction.request.url,
              let host = url.host, !["localhost", "127.0.0.1"].contains(host)
        else {
            decisionHandler(.allow)
            return
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    // MARK: Console bridge (development aid: renderer console → stdout)

    // MARK: Page styles

    /// Extra CSS for the overlay page by key (e.g. hiding a web widget that SwiftExile replaces
    /// natively). Applied now and again after every page load.
    private var pageStyles: [String: String] = [:]

    func setPageStyle(_ key: String, css: String?) {
        pageStyles[key] = css
        apply(styleKey: key)
    }

    private func apply(styleKey key: String) {
        let id = "swiftexile-style-\(key)"
        let css = pageStyles[key] ?? ""
        let script = """
        (function () {
          let style = document.getElementById(\(Self.jsString(id)));
          const css = \(Self.jsString(css));
          if (!css) { if (style) style.remove(); return; }
          if (!style) { style = document.createElement('style'); style.id = \(Self.jsString(id)); document.head.appendChild(style); }
          style.textContent = css;
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        for key in pageStyles.keys { apply(styleKey: key) }
    }

    private static func jsString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    /// Called with the time from receiving item text to the next painted frame (milliseconds).
    var onPaintLatency: ((Double) -> Void)?
    /// Called for the renderer's console warnings and errors (level, text), so they reach the log
    /// file even when SwiftExile is started from Finder (stdout goes nowhere then).
    var onConsoleProblem: ((String, String) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "latency", let body = message.body as? [String: Any], let ms = body["ms"] as? Double {
            onPaintLatency?(ms)
            return
        }
        guard let body = message.body as? [String: Any],
              let level = body["level"] as? String,
              let text = body["msg"] as? String
        else { return }
        print("[web:\(level)] \(text)")
        if level == "warn" || level == "error" { onConsoleProblem?(level, text) }
    }

    /// Measures item text arriving over the WebSocket → the next painted frame. Listens before the
    /// renderer's own handler (registered at construction), then waits two animation frames:
    /// the first runs after Vue's DOM update, the second after that frame was painted.
    private static let paintTimer = """
    (function () {
      const Original = window.WebSocket;
      function TimedWebSocket(url, protocols) {
        const socket = protocols === undefined ? new Original(url) : new Original(url, protocols);
        socket.addEventListener('message', (event) => {
          if (typeof event.data !== 'string' || !event.data.includes('"MAIN->CLIENT::item-text"')) return;
          const start = performance.now();
          requestAnimationFrame(() => requestAnimationFrame(() => {
            try { window.webkit.messageHandlers.latency.postMessage({ ms: performance.now() - start }); } catch (e) {}
          }));
        });
        return socket;
      }
      TimedWebSocket.prototype = Original.prototype;
      for (const key of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) TimedWebSocket[key] = Original[key];
      window.WebSocket = TimedWebSocket;
    })();
    """

    private static let consoleBridge = """
    (function () {
      const post = (level, args) => {
        try {
          const msg = args.map((a) => {
            if (typeof a === 'string') return a;
            if (a instanceof Error) return `${a.name}: ${a.message}\n${a.stack || ''}`;
            try { return JSON.stringify(a); } catch (e) { return String(a); }
          }).join(' ');
          window.webkit.messageHandlers.console.postMessage({ level, msg });
        } catch (e) {}
      };
      for (const level of ['log', 'info', 'warn', 'error']) {
        const original = console[level].bind(console);
        console[level] = (...args) => { post(level, args); original(...args); };
      }
      window.addEventListener('error', (e) => post('error', [`${e.message} @ ${e.filename}:${e.lineno}`]));
      window.addEventListener('unhandledrejection', (e) =>
        post('error', ['unhandledrejection: ' + ((e.reason && e.reason.stack) || e.reason)]));
    })();
    """
}
