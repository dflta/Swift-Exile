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
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "console")
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

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let level = body["level"] as? String,
              let text = body["msg"] as? String
        else { return }
        print("[web:\(level)] \(text)")
    }

    private static let consoleBridge = """
    (function () {
      const post = (level, args) => {
        try {
          const msg = args.map((a) => {
            if (typeof a === 'string') return a;
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
