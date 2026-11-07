# Installing SwiftExile

SwiftExile runs on macOS 14 (Sonoma) or later, on Apple Silicon and Intel Macs. It works with Path
of Exile 2's Windows client under NotProton, CrossOver, or Whisky.

## 1. Download

Get the latest `SwiftExile-<version>.dmg` from
[Releases](https://github.com/dflta/Swift-Exile/releases/latest), open it, and drag
**SwiftExile** onto **Applications**.

## 2. First launch: allow it in Privacy & Security

SwiftExile isn't notarized by Apple (that needs a paid Apple Developer account), so macOS blocks the
first launch:

1. Open SwiftExile from Applications. macOS says it *could not verify* SwiftExile. Click **Done**
   (not "Move to Trash").
2. Open **System Settings ▸ Privacy & Security** and scroll down to **Security**. Next to
   "SwiftExile was blocked to protect your Mac", click **Open Anyway**, and confirm with your
   password or Touch ID.
3. Open SwiftExile again and click **Open**.

You only do this once. Updates install through SwiftExile itself and aren't blocked.

Prefer Terminal? This does the same:

```bash
xattr -dr com.apple.quarantine /Applications/SwiftExile.app
```

## 3. Allow Accessibility

SwiftExile needs **Accessibility** access to follow the game window and to read the hotkeys you
press in the game. On first launch it opens a window that explains this:

1. Open **System Settings ▸ Privacy & Security ▸ Accessibility**.
2. Turn on **SwiftExile**. If it isn't listed, click **+** and pick it from Applications.

The window closes by itself once access is granted. Releases are all signed with the same
certificate, so macOS keeps this permission when SwiftExile updates.

If SwiftExile is listed but hotkeys still don't work (this can happen after switching from a
self-built copy), remove it from the list with **−**, then add it again with **+**.

## 4. Use it

- Start Path of Exile 2. The menu bar icon changes from a dashed circle to a target when SwiftExile
  finds the game.
- Default hotkeys come from Exiled Exchange 2's settings (open the overlay with **Shift + Space**,
  then Settings): price check **Alt + D** (hold Alt) or **Ctrl + D**.
- SwiftExile and the Electron version of Exiled Exchange 2 share the same settings file. Don't run
  both at the same time.

## Updates

SwiftExile checks for updates automatically (you can turn this off in Settings ▸ About), or use
**Check for Updates…** in the menu bar.

## Uninstall

Quit SwiftExile, then delete it from Applications. Settings shared with Exiled Exchange 2 stay in
`~/Library/Application Support/exiled-exchange-2/`; logs are in `~/Library/Logs/SwiftExile/`.
