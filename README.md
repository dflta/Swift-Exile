# SwiftExile

A native macOS host for [Exiled Exchange 2](https://github.com/Kvan7/Exiled-Exchange-2) by Kvan7, itself a fork of [Awakened PoE Trade](https://github.com/SnosMe/awakened-poe-trade) by SnosMe.

SwiftExile replaces the Electron shell with a native Swift app and is moving the user interface to native SwiftUI, starting with the price check. Until each part is rebuilt, the overlay runs Exiled Exchange 2's own web UI and item parser, **unchanged**, in `WKWebView`. Upstream is included as a git submodule in [`upstream/`](upstream), so every build states exactly which upstream commit it uses.

Not affiliated with or endorsed by Grinding Gear Games.

> **Status:** early prototype (day 2). Native SwiftUI menu bar item and Settings window; the overlay follows the game window (tested with the Windows client under NotProton/CrossOver). Hotkeys and the native price check are not implemented yet; the overlay still shows Exiled Exchange 2's web widgets, which will be replaced by SwiftUI step by step.

## Build

Requirements: macOS 14+, Xcode (Swift 6), Node.js (build time only).

```bash
git submodule update --init
Scripts/bundle-app.sh            # builds the renderer and build/SwiftExile.app
open build/SwiftExile.app
```

`swift test` runs the host's unit and integration tests.

### Development flags

| Flag / variable | Effect |
|---|---|
| `SWIFTEXILE_DATA_DIR=<dir>` | Use another settings folder instead of `~/Library/Application Support/exiled-exchange-2/apt-data` (shared with the Electron app) |
| `SWIFTEXILE_DEV_SERVER_URL=http://localhost:5173` | Load the renderer from a Vite dev server (`npm run dev` in `upstream/renderer`); the host listens on 8584 |
| `--browser-mode` | Run the renderer as a plain browser client instead of overlay mode |
| `--listen=[host][:port]` | Server address, as in upstream |

Do not run SwiftExile and the Electron app at the same time: they share the settings file.

## License

SwiftExile is MIT-licensed. It bundles Exiled Exchange 2, which is MIT-licensed by its authors; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
