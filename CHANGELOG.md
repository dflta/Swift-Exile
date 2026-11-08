# Changelog

## 0.1.4

- **Native map check.** The item check hotkey on a waystone, tablet, or contract shows its
  properties and modifiers. Click a modifier to mark it dangerous, warning, or good; ratings are
  kept per profile (I, II, III) and shared with Exiled Exchange 2's map check.
- **Settings ▸ Map Check:** rate any map modifier ahead of time, with search and "only rated".
  Includes newer tablet modifiers Exiled Exchange 2 doesn't list yet, and modifiers it doesn't
  recognize on a map can still be rated.
- Fixed: changing a setting in SwiftExile showed Exiled Exchange 2's "Is ready and running in
  background" pop-up.

## 0.1.3

- **Native item check.** Set its hotkey in Settings ▸ Hotkeys. It shows the item's modifiers with
  their tiers and roll ranges, weapon DPS, defences, the skill an item grants, and requirements,
  with buttons for the wiki, poe2db, Craft of Exile, finding the item in your stash, and a price
  check. Quest items get a wiki link. Maps still open Exiled Exchange 2's map check.
- Settings no longer let you give two actions the same hotkey; they tell you what already uses it.
- Fixed: Find in stash sometimes put the whole item text into the stash search, or did nothing
  after the item check closed.

## 0.1.2

- **SwiftExile bar.** Open the overlay (Shift + Space) to get SwiftExile's own bar: settings, stash
  searches, the experience tracker, and a field to paste an item for a price check.
- **Settings inside the overlay**, and in a new window from the menu bar: hotkeys, price check, chat
  commands, stash searches, and leveling. Changes apply right away.
- **Experience tracker.** Shows your level, the experience you get in the current area, and how far
  you are over the ideal area level. Turn it on with XP on the bar or in Settings ▸ Leveling.
- Exiled Exchange 2's leveling widgets can read the game log (Settings ▸ Leveling).
- Drag the bar, the experience tracker, the settings, and the price check anywhere; they remember
  their place.
- New app and menu bar icons.
- SwiftExile is now free for noncommercial use under the PolyForm Noncommercial License 1.0.0.

## 0.1.1

- First update through the built-in updater.

## 0.1.0

First public release.

- Native macOS host for Exiled Exchange 2: overlay over the game (windowed, borderless, and
  fullscreen), game window tracking under NotProton, CrossOver, and Whisky.
- Hotkeys from Exiled Exchange 2's settings: price check (hold and locked), overlay, chat
  commands (including `@last`), stash search, Ctrl + mouse wheel stash tab switching.
- Native price check (preview): roll sliders, tier badges, poe.ninja price per item and
  per stack with a 7-day trend, item filters, presets, rune and catalyst editor, trade listings
  and bulk exchange offers, league picker, pin.
- Updates itself from inside the app.
