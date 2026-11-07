# SwiftExile

A native macOS host for [Exiled Exchange 2](https://github.com/Kvan7/Exiled-Exchange-2) by Kvan7, itself a fork of [Awakened PoE Trade](https://github.com/SnosMe/awakened-poe-trade) by SnosMe.

SwiftExile replaces the Electron shell with a native Swift app and is moving the user interface to native SwiftUI, starting with the price check. Until each part is rebuilt, the overlay runs Exiled Exchange 2's own web UI and item parser, **unchanged**, in `WKWebView`. Upstream is included as a git submodule in [`upstream/`](upstream), so every build states exactly which upstream commit it uses.

Not affiliated with or endorsed by Grinding Gear Games.

> **Status:** early beta. Native SwiftUI menu bar item, Settings window, and a **native SwiftUI price check (preview)**: roll sliders, tier badges, poe.ninja price and trend, item filters, a rune and catalyst editor, trade listings and bulk exchange offers. Its data comes from Exiled Exchange 2's own parser and trade logic, run headless (`Engine/`). Other widgets still use Exiled Exchange 2's web UI in the overlay; Settings ▸ Price Check switches the price check back to it. Hotkeys, chat commands, stash search, and stash tab scrolling work as in Exiled Exchange 2. Tested with the Windows client under NotProton/CrossOver.

## Install

Download the DMG from [Releases](https://github.com/dflta/Swift-Exile/releases/latest) and follow [Documentation/install.md](Documentation/install.md): SwiftExile isn't notarized, so the first launch needs one click in Privacy & Security. Updates install through the app (Sparkle).

## Build

Requirements: macOS 14+, Xcode (Swift 6), Node.js (build time only).

```bash
git submodule update --init
Scripts/bundle-app.sh            # builds the renderer and build/SwiftExile.app
open build/SwiftExile.app
```

`swift test` runs the host's unit and integration tests. Overlay and window-tracking checks need the real game; see [Documentation/testing.md](Documentation/testing.md), run them with `Scripts/run-diagnostics.sh`, and use `swift Scripts/transition-test.swift` for the automated transition check. The app always logs to `~/Library/Logs/SwiftExile/swiftexile.log` (menu bar ▸ Show Log).

### Development flags

| Flag / variable | Effect |
|---|---|
| `SWIFTEXILE_DATA_DIR=<dir>` | Use another settings folder instead of `~/Library/Application Support/exiled-exchange-2/apt-data` (shared with the Electron app) |
| `SWIFTEXILE_DEV_SERVER_URL=http://localhost:5173` | Load the renderer from a Vite dev server (`npm run dev` in `upstream/renderer`); the host listens on 8584 |
| `--browser-mode` | Run the renderer as a plain browser client instead of overlay mode |
| `--debug-native-item=<file>` | Show a saved item's text in the native price check (no game needed) |
| `--listen=[host][:port]` | Server address, as in upstream |
| `SWIFTEXILE_TRACE_FOCUS=1` | Log every overlay focus change and focus reclaim |
| `SWIFTEXILE_ACTIVATION=app` | Activate SwiftExile whenever the overlay becomes interactive (diagnostics) |
| `SWIFTEXILE_RETOGGLE=1` / `0` | Force re-pressing (or not) modifiers you're holding when copying an item; by default only the native client re-presses them |

Do not run SwiftExile and the Electron app at the same time: they share the settings file.

### Item data supplement

The native price check uses Exiled Exchange 2's item data. A few augment effects are missing from
it (for example Rabbit Idol's "Sceptres: 15% increased Spirit"), so socketed augments would show as
unknown. [`Engine/augment-supplement.json`](Engine/augment-supplement.json) adds them when the engine starts, and lists
the gaps it can't fill yet. Entries were checked against poe2db.tw; remove them once upstream ships
the data.

Releases: [Documentation/releasing.md](Documentation/releasing.md).

## License

SwiftExile is **source-available** under the [PolyForm Noncommercial License 1.0.0](LICENSE): free for personal, hobby, research, and other noncommercial use, including sharing modified copies under the same terms. Selling it, or using it in a commercial product or service, needs permission from the author. Versions 0.1.0 and 0.1.1 were released under the MIT License and stay available under it.

It bundles Exiled Exchange 2, which keeps its own MIT License, and other open-source components under their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The name "SwiftExile" and its icon aren't covered by the license: modified copies must use a different name.

Contributions are welcome and are accepted under the same license.
