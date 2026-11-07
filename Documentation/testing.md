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

Stash search, chat macros, Ctrl+wheel stash scrolling, and the heist OCR key are not implemented
on macOS yet; their hotkeys log `this action is not implemented on macOS yet`.

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
