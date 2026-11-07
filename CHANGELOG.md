# Changelog

## 0.1.2

- **License change:** SwiftExile's own code is now under the PolyForm Noncommercial License 1.0.0
  (free for noncommercial use; selling or commercial use needs permission). 0.1.0 and 0.1.1 stay
  available under the MIT License. Bundled components such as Exiled Exchange 2 keep their own
  licenses.
- The app's copyright line and Settings ▸ About now credit © 2026 dflta.
- New app icon, and SwiftExile's emblem in the menu bar (dimmed while waiting for the game).
- **SwiftExile window** (menu bar ▸ Settings…) replaces the old Settings window: a sidebar with
  Game, Hotkeys, Price Check, Chat Commands, Stash Search, Leveling, Permissions, and About. The
  overlay settings SwiftExile implements (price check hotkeys and options, overlay key, stash tab
  scrolling, clipboard restore, chat commands, stash searches, client log) can be edited there, with
  a hotkey recorder; changes apply right away and stay in sync with the overlay. Stash searches can be
  run from the window.
- **SwiftExile bar** in the open overlay (next to Exiled Exchange 2's widget menu): settings inside the
  overlay (like Exiled Exchange 2's own Settings), stash searches, the experience tracker switch, and a
  paste-to-price-check field, with standard macOS controls. The bar and the experience tracker can be
  moved by a ✥ grab tab beside them while the overlay is open; the in-overlay settings and the native
  price check move by dragging their header. They remember where you put them,
  and settings left open come back when the overlay opens again. The overlay key closes the overlay
  while the settings have keyboard focus.
- **Native experience tracker** (Settings ▸ Leveling): your level, the experience you get in the
  current area, and how far over the ideal area level you are, above the experience bar. It knows
  your level and zone right away from the log's history, and works in every client language.
- Game log support: SwiftExile follows the game's `Client.txt` (found automatically next to the
  running game) for its own tracker and, when allowed in the overlay's settings, for Exiled
  Exchange 2's leveling widgets; it also writes the library feature's data files. Handles the
  Windows client's line endings, lines split across reads, and a truncated or replaced log.
- Overlay console warnings and errors, and the text of each chat command or stash search SwiftExile
  types, now go to SwiftExile's log file.
- Release notes (on GitHub and in the update dialog) now come from this changelog.

## 0.1.1

- First update delivered through Sparkle. Checks that installed copies update in place and keep
  their Accessibility permission (all releases are signed with the same certificate).
- Added this changelog.

## 0.1.0

First public release.

- Native macOS host for Exiled Exchange 2: overlay over the game (windowed, borderless, and
  fullscreen), game window tracking under NotProton, CrossOver, and Whisky.
- Hotkeys from Exiled Exchange 2's settings: price check (hold and locked), overlay, chat
  commands (including `@last`), stash search, Ctrl + mouse wheel stash tab switching.
- Native SwiftUI price check (preview): roll sliders, tier badges, poe.ninja price per item and
  per stack with a 7-day trend, item filters, presets, rune and catalyst editor, trade listings
  and bulk exchange offers, league picker, pin.
- Signed with a stable self-signed certificate; updates through Sparkle.
