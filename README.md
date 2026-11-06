# SwiftExile

A native macOS host for [Exiled Exchange 2](https://github.com/Kvan7/Exiled-Exchange-2) by Kvan7, itself a fork of [Awakened PoE Trade](https://github.com/SnosMe/awakened-poe-trade) by SnosMe.

The entire user interface and item parser come from Exiled Exchange 2, **unchanged**. SwiftExile replaces only the Electron shell with a Swift/AppKit app that serves the renderer and shows it in `WKWebView`. Upstream is included as a git submodule in [`upstream/`](upstream), so every build states exactly which upstream commit it uses.

Not affiliated with or endorsed by Grinding Gear Games.

> **Status:** early prototype (day 1). The renderer runs in a normal window; the game overlay, hotkeys, and price-check flow are not implemented yet.

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
