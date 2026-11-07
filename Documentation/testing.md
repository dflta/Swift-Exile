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
| T8 | Move the game to the second display, windowed and fullscreen | Overlay follows to the second display with correct size |
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

If F1 or F3 fails, the log shows `reclaiming key focus` lines and possibly
`the game kept taking keyboard focus back`. Note which game state it was; that is the data needed
to fix risk R6.

## Reading the log

- `[GameWindow] geometry changed 412 ms after Space change` — time from a transition to the
  overlay's new position. The prototype target is ≤ 500 ms (95th percentile).
- `[Focus] reclaiming key focus (attempt N)` — the game took keyboard focus back and SwiftExile
  retook it. Attempt 3 also activates SwiftExile.
- `[Focus] focus update gameFrontmost=… panelKey=… → [...]` — every overlay state change.
