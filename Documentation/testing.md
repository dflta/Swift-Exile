# Manual test checklist: overlay and window tracking

These checks need the real game and real display changes, so they can't run in CI.
Run them on every release, and whenever the window tracking or overlay focus code changes.

## Setup

1. Quit the Electron version of Exiled Exchange 2 (both apps share the settings file).
2. Build and start a diagnostics session:

   ```bash
   Scripts/bundle-app.sh
   Scripts/run-diagnostics.sh
   ```

   It uses a copy of your settings and writes a log to `~/Library/Logs/SwiftExile/`.
3. Start Path of Exile 2 (or have it running). The menu bar item changes from a dashed circle to
   a target icon when SwiftExile attaches.

Note the result of each step (pass / fail / what you saw). Attach the log file when reporting.

## Automated transition test

With the game and SwiftExile running (game in front), run:

```bash
swift Scripts/transition-test.swift --cycles=10            # app switching
swift Scripts/transition-test.swift --cycles=10 --spaces   # plus Space switching (needs a second Space)
```

It switches apps (and Spaces) away and back and checks the window server's real window positions,
independently of SwiftExile. Don't touch the keyboard or mouse while it runs. Pass: 0 failures,
p95 ≤ 500 ms, max ≤ 1500 ms. Space switches that macOS applies to another display are reported as
skipped.

## Permissions (first launch from Finder)

1. Open `build/SwiftExile.app` from Finder.
2. Expected: a macOS prompt for Accessibility, or, if SwiftExile is listed from an older build,
   SwiftExile's own "needs Accessibility access" window after 3 s.
3. Grant Accessibility (if listed from an older build: remove with "−", add again with "+").
4. Expected: the window closes by itself; the menu bar shows the game as attached; hotkeys work.
   No Input Monitoring prompt is expected.

## Window tracking

| # | Step | Expected |
|---|---|---|
| T1 | Start SwiftExile first, then the game | Attaches within a few seconds of the game window appearing; log shows `attached to "Path of Exile 2"` |
| T2 | In windowed mode, move and resize the game window | Overlay follows; log shows `geometry changed … ms after window moved/resized` |
| T3 | Switch the game to fullscreen (in-game setting, and the green button if available) | Overlay covers the whole screen with no gap at the top, within about half a second |
| T4 | Switch back to windowed | Overlay matches the window's content area (title bar not covered) |
| T5 | While playing fullscreen, switch to another Space (Ctrl+→) and back | Overlay hidden on the other Space, correct on return |
| T6 | ⌘-Tab to another app and back, in windowed and fullscreen | Hidden while away, shown and click-through on return |
| T7 | Open Mission Control during play, then close it | Overlay not stuck on top of Mission Control; correct afterwards |
| T8 | Move the game to the second display, windowed and fullscreen | Overlay follows to the second display with correct size. **Deferred:** under CrossOver, moving the game to another display needs a game restart, so this is run as a regression check once the native client ships (see "Deferred regression checks") |
| T9 | Change the game resolution, or plug/unplug a display | Overlay re-snaps |
| T10 | Minimize or hide (⌘H) the game | Overlay hidden |
| T11 | Quit the game and start it again | Detaches, then attaches again |
| T12 | Change "Window title" in the overlay settings to something else, then back | Detaches, then re-attaches |

## Overlay focus

Use the menu bar item's **Show Overlay** (or the overlay key once hotkeys exist).

| # | Step | Expected |
|---|---|---|
| F1 | Show Overlay while playing | Overlay becomes interactive and stays so; you can click widgets and type in a field |
| F2 | Press Escape, Ctrl+W, or the overlay key inside the overlay | Back to the game; game gets keyboard input again |
| F3 | Repeat F1 in different game states: in town, in a map, in a menu, on the loading screen | Note any state where the overlay drops back to click-through by itself |
| F4 | Show Overlay, then ⌘-Tab to another app | Overlay hides; it does not fight to stay in front |

Test F1–F3 in **both windowed and windowed fullscreen**. Under Wine, windowed fullscreen makes the
game grab keyboard focus about once a second; SwiftExile takes it back each time, so the overlay
should stay interactive. The log shows `game took keyboard focus; retaking (N this session)` and,
when the overlay closes, `the game grabbed keyboard focus N time(s)`. If the overlay still drops to
click-through by itself, note the mode and game state.

## Hotkeys and price check

The hotkeys come from the overlay's own settings (Exiled Exchange 2). Defaults on the dev Mac:
price check `Alt + D` (hold Alt), locked price check `Ctrl + D`, overlay key `Shift + Space`.
Global hotkeys work only while the game window is in front, like upstream.

| # | Step | Expected |
|---|---|---|
| H1 | Hover an item, press the price check key (hold mode: keep Alt held) | Price check opens next to the item; prices load. Log: `item copied in … ms → price-check` |
| H2 | Same with the locked key (`Ctrl + D`) | Price check opens and the overlay takes focus (you can click filters) |
| H3 | In hold mode, release Alt and move the mouse away | Price check closes; moving into it instead keeps it and makes it clickable |
| H4 | Press the overlay key in the game | Overlay toggles; pressing it again (or Escape) returns to the game |
| H5 | Hold Alt alone (no other key) in the game | Overlay hides after ~0.3 s so the game's own tooltip is visible; releasing Alt shows it again |
| H6 | Press a hotkey while another app is in front | Nothing happens; the key reaches that app normally |
| H7 | Hover nothing and press the price check key | Log: `No item text found.`; nothing else happens |

### Native price check (preview)

With menu bar ▸ "Native Price Check (Preview)" on (default):

| # | Step | Expected |
|---|---|---|
| N1 | Price check a unique with the hold key | Native panel next to the stash/inventory panel: name in unique colour, poe.ninja price, filters, trade listings searched automatically. Moving the mouse away (Alt released) closes it |
| N2 | Price check a rare with the locked key | Panel takes focus; tick filters, change a minimum (Enter), press "Search trade"; listings update. Esc closes it |
| N3 | Price check currency (e.g. Divine Orb) | "Search bulk exchange"; offers grouped by the currency you pay with |
| N4 | Turn the preview off and repeat N1 | Exiled Exchange 2's web price check appears instead |
| N5 | Price check a unique and a rare with the locked key | Stats with a roll range show a slider: track = possible rolls (unique) or tier range (rare), yellow tick = this item's roll, highlighted part = what's searched. Dragging an end changes min/max and ticks the filter; min/max fields match. T1/T2 badges on tiered mods |
| N6 | On a rare: switch "Rider Bow / Any Bow", the Pseudo / Base item presets, item chips (Item Level with its stepper, Corrupted), and the listing / listed / currency menus; search after each | Filters change as in Exiled Exchange 2; old results clear until you search again |
| N7 | Press the ↗ button (and a bulk group's ↗) | The same search opens on the trade site in the browser; the poe.ninja row opens poe.ninja |
| N8 | With the panel open, click in the game (or walk); then pin it (📌) and click in the game again | Unpinned: the panel closes. Pinned: it stays. Clicking a trade menu's items never closes it |
| N9 | With the panel open, ⌘-Tab to another app and back | Unpinned: closed. Pinned: hidden while away, back with the game |
| N11 | Pick another league from the header's league menu | The item is priced again in that league (poe.ninja and trade); this lasts until SwiftExile restarts |
| N12 | Price check a rare weapon or armour with a socket; open the socket section, pick a rune | The rune's mod appears as an "added rune" filter; Each mod / Pseudo still work. A rare ring/amulet shows catalysts instead: pick one and a quality; the boosted mods change and the catalysts' cost shows |
| N13 | Price check a currency stack (e.g. 3 Divine Orbs); change the Stock amount | poe.ninja shows the price each and for the whole amount |
| N14 | Search a unique with runes in its sockets (e.g. The Brass Dome); open the socket section and click each socket; then click a listing | Sockets show the item's runes; clicking a socket jumps to its rune in the list. The listing opens that seller's item on the trade site |
| N10 | Price check a unique with resistances (e.g. Blistering Bond); choose "Each mod" | Every modifier is its own filter (e.g. cold resistance), with its roll range slider; hidden filters show why they're hidden |

Without the game: `build/SwiftExile.app/Contents/MacOS/SwiftExile --debug-native-item=<item.txt>` shows a saved item.

### Chat, stash search, stash scrolling

Set these up in the overlay's settings (Exiled Exchange 2): chat commands under Chat, stash search
under Stash search, and "Ctrl + scroll wheel switches stash tabs". The heist OCR key is not
implemented on macOS (upstream runs it only on Windows).

| # | Step | Expected |
|---|---|---|
| H8 | Press a chat command hotkey (e.g. `/hideout`, with "send" on) | Chat opens, the command is pasted and sent, chat goes back to what it was. Your clipboard is restored if "restore clipboard" is on |
| H9 | Chat command `@last thanks` after someone whispered you | Reply goes to the last whisper |
| H10 | Chat command `/invite @last` | Invites the last person who whispered you |
| H11 | With the stash open, press a stash-search hotkey; also use the stash search widget in the overlay | The stash search field gets the text and highlights matches; from the overlay, the game gets focus first |
| H12 | Turn on Ctrl + wheel stash scrolling; hold Ctrl and scroll with the mouse outside the stash grid, then over it | Outside: one tab per wheel step (no flood from a trackpad swipe). Over the grid: the game's own scrolling |
| H13 | Press a chat hotkey twice quickly | The second press is ignored while the first is running (no garbled chat) |

If Ctrl + scroll zooms the screen instead, macOS's accessibility zoom is set to Ctrl + scroll
(System Settings ▸ Accessibility ▸ Zoom); pick another modifier there.

## Game log (client log) features

SwiftExile finds the game's `Client.txt` next to the running game (Wine install folder) unless a
path is set in the overlay's settings. It reads the log when either is on:
Settings ▸ Leveling ▸ **Experience tracker** (SwiftExile's native widget), or the overlay's
Settings ▸ Leveling ▸ "Allow reading of Client.txt file" (Exiled Exchange 2's widgets).

| # | Step | Expected |
|---|---|---|
| G1 | Turn on the experience tracker, with the game running | Log: `following …/Path of Exile 2/logs/Client.txt` and `[Leveling] from the log: level N, area level M` (your current level, without waiting for a level-up) |
| G2 | Look above the experience bar while playing | A small "Lv · Area · Exp · Over" panel; clicks pass through it; it hides when another app is in front |
| G3 | Change zones (a combat area, then a town) | Area and Exp update for the combat area; towns and hideouts don't change them |
| G4 | Level up | Lv updates |
| G5 | Turn on "Allow reading of Client.txt file" in the overlay; change zones | Exiled Exchange 2's XP widget also updates (log: `overlay saw load-zone …`) |
| G6 | Turn both off | Log: `[GameLogWatcher] disabled`; the panel disappears |
| G7 | With the library alpha enabled (overlay Settings ▸ General ▸ alphas), use it | Data files appear under `apt-data/csv-data/` (or the folder set for it) |

## SwiftExile window (Settings)

| # | Step | Expected |
|---|---|---|
| W1 | Menu bar ▸ Settings… | Window with a sidebar: Game, Hotkeys, Price Check, Chat Commands, Stash Search, Leveling, Permissions, About; your current overlay settings are shown |
| W2 | Hotkeys ▸ "Open without auto-hide" (the price check that stays open and takes focus): click the field, press F6. In the game hover an item and press F6, then the old key | Field shows `F6`; F6 opens the price check right away (no restart); the old key does nothing. Set it back afterwards |
| W3 | Press Backspace while recording a key; press Esc while recording | Backspace clears it; Esc keeps the old one |
| W4 | Chat Commands: add `/played` with a hotkey, Send on | The hotkey types and sends it in the game |
| W5 | Stash Search: open the stash in the game, press ▶ on an entry | The game comes to the front and the stash search box gets the text |
| W6 | Change a setting in the overlay's own Settings and save; look at the window | The window shows the change |
| W7 | Change a setting in the window, then open the overlay's Settings | The overlay shows the change |
| W8 | Open the overlay (Shift + Space) | SwiftExile's own bar appears with standard macOS controls (⚙, 🔍, XP, "Price check (⌘V)"), no emblem; it disappears when the overlay closes |
| W9 | Drag the bar and the XP panel by the ✥ grab tab on their left (the XP tab shows only while the overlay is open), and the settings by their header; close and reopen the overlay | The tab sits outside the panel, so the panel keeps its size when the tab appears; each stays where you put it; in the game the XP panel is click-through again, without a tab |
| W9c | Open a price check, drag it by its header (item name area), then expand a section | The panel moves and grows downward from its new place; the league menu, pin and ✕ in the header still work; clicking outside still closes it (unless pinned) |
| W9b | Open the overlay, then ⌘-Tab to another app and back | The bar, the settings, and the XP panel disappear with the overlay. Back in the game the overlay is closed (like Exiled Exchange 2): only the XP panel returns; Shift + Space brings the bar back |
| W10 | ⚙ on the bar | SwiftExile's settings open inside the overlay, centered over the game; Esc, ✕, or ⚙ closes them |
| W10b | Open the settings from ⚙, close the overlay (Shift + Space or ⌘-Tab away), then open the overlay again | The settings hide with the overlay and come back with it, until closed with Esc, ✕, or ⚙ |
| W10c | Open the settings from ⚙ (they take keyboard focus), press Shift + Space; reopen, click into a hotkey field and press Shift + Space while it records | The first closes the overlay (no beep) and the settings come back with it; while recording, Shift + Space is recorded instead |
| W11 | In those settings, type in a field and record a hotkey for a few seconds (windowed fullscreen) | Typing and recording keep working (the game's focus grabs return focus to the settings) |
| W12 | 🔍 on the bar, pick a search (stash open in the game) | The game comes to the front and the stash search box gets the text |
| W13 | XP on the bar | Turns the experience tracker on and off |
| W14 | Copy an item (Ctrl + C in the game), click the bar's price check field, ⌘V | The native price check opens for that item |

## Deferred regression checks

Not run yet because of the current game setup; run them before the first release that supports the
native macOS client, and after any change to window tracking or overlay placement.

| # | Check | Why deferred | Steps |
|---|---|---|---|
| T8 | Second display | CrossOver needs a game restart to move the window between displays (2026-11-07) | Windowed: drag the game to the other display, press the overlay key and a price check key; overlay and price check must appear on that display, aligned. Then the same in windowed fullscreen on that display. Optional: window straddling both displays. Log lines `geometry changed … window (x, y, w×h) → overlay (…)` must show matching rects |

## Reading the log

- `[GameWindow] geometry changed 412 ms after Space change` — time from a transition to the
  overlay's new position. The prototype target is ≤ 500 ms (95th percentile).
- `[Focus] game took keyboard focus; retaking (N this session)` — the game grabbed keyboard focus
  while the overlay was interactive, and SwiftExile took it back (at most once per 150 ms).
- `[Focus] focus update gameFrontmost=… panelKey=… → [...]` — every overlay state change.
