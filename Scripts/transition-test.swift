// Scripted transition test for go/no-go criterion G1 (plan §5.1).
//
// Requires: the game running, SwiftExile running and attached. It switches apps (and optionally
// Spaces) away from the game and back, and after each step asks the window server where the game
// window and the overlay actually are. It does not trust SwiftExile's own log.
//
// Usage: swift Scripts/transition-test.swift [--cycles=10] [--spaces] [--other-app=Finder]
//   --spaces needs a second Space and the default "Move left/right a space" shortcuts (Ctrl+←/→).
import AppKit

let arguments = CommandLine.arguments.dropFirst()
func option(_ name: String) -> String? {
    arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
}
let cycles = Int(option("cycles") ?? "") ?? 10
let testSpaces = arguments.contains("--spaces")
let otherApp = option("other-app") ?? "Finder"
let gameProcess = "PathOfExileSteam.exe"
let tolerance: CGFloat = 1
let timeout: TimeInterval = 2

// MARK: Window server

struct WindowInfo { var bounds: CGRect; var layer: Int }

func onScreenWindows(owner: String) -> [WindowInfo] {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    return list.compactMap { entry in
        guard entry[kCGWindowOwnerName as String] as? String == owner,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict)
        else { return nil }
        return WindowInfo(bounds: bounds, layer: entry[kCGWindowLayer as String] as? Int ?? 0)
    }
}

func gameWindow() -> WindowInfo? {
    onScreenWindows(owner: gameProcess).max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
}

func overlayWindow() -> WindowInfo? {
    onScreenWindows(owner: "SwiftExile").first { $0.layer >= 1000 }
}

let titleBarHeight: CGFloat = {
    let probe = NSRect(x: 0, y: 0, width: 400, height: 400)
    return NSWindow.frameRect(forContentRect: probe, styleMask: [.titled]).height - probe.height
}()

/// The overlay must cover the game's drawable area: same width and bottom edge, and either the
/// full height (borderless/fullscreen) or the height minus a title bar (windowed).
func isAligned(overlay: CGRect, game: CGRect) -> Bool {
    func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
    guard close(overlay.minX, game.minX), close(overlay.width, game.width), close(overlay.maxY, game.maxY) else { return false }
    return close(overlay.height, game.height) || close(overlay.height, game.height - titleBarHeight)
}

// MARK: Actions

func run(_ script: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

func focusGame() { run("tell application \"System Events\" to set frontmost of (first process whose name is \"\(gameProcess)\") to true") }
func focusOther() { run("tell application \"\(otherApp)\" to activate") }

/// With "Displays have separate Spaces", Ctrl+←/→ switches Spaces on the active display, which can
/// be the other one (seen: Steam's display). Put the pointer on the game's display first.
func pointAtGameDisplay() {
    guard let game = gameWindow()?.bounds else { return }
    CGWarpMouseCursorPosition(CGPoint(x: game.midX, y: game.midY))
    usleep(50_000)
}

func pressSpaceShortcut(right: Bool) {
    pointAtGameDisplay()
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: right ? 124 : 123, keyDown: down)!
        event.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        event.post(tap: .cghidEventTap)
        usleep(20_000)
    }
}

// MARK: Measurement

struct Result { var name: String; var passed: Bool; var milliseconds: Int; var detail: String }
var results: [Result] = []
var skipped = 0

/// Polls the window server until `condition` holds or the timeout passes.
func measure(_ name: String, _ condition: () -> (ok: Bool, detail: String)) {
    let start = Date()
    var last = (ok: false, detail: "")
    while Date().timeIntervalSince(start) < timeout {
        last = condition()
        if last.ok { break }
        usleep(25_000)
    }
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    results.append(Result(name: name, passed: last.ok, milliseconds: ms, detail: last.detail))
    print(String(format: "  %-30@ %@ %5d ms  %@", name as NSString, last.ok ? "ok  " : "FAIL", ms, last.detail))
}

func overlayAlignedWithGame() -> (ok: Bool, detail: String) {
    guard let game = gameWindow() else { return (false, "game window not on screen") }
    guard let overlay = overlayWindow() else { return (false, "overlay not on screen") }
    let ok = isAligned(overlay: overlay.bounds, game: game.bounds)
    return (ok, ok ? "" : "overlay \(overlay.bounds) vs game \(game.bounds)")
}

func overlayHidden() -> (ok: Bool, detail: String) {
    overlayWindow() == nil ? (true, "") : (false, "overlay still on screen over \(otherApp)")
}

/// Space switch away: macOS animates the switch, and windows of the old Space leave the on-screen
/// list only when it ends. The overlay is correct if it is gone no later than the game itself.
/// Records the overlay's delay relative to the game (0 when it left first or together).
func measureSpaceAway(_ name: String) {
    let start = Date()
    var overlayGone: TimeInterval?
    var gameGone: TimeInterval?
    while Date().timeIntervalSince(start) < timeout, overlayGone == nil || gameGone == nil {
        let now = Date().timeIntervalSince(start)
        if overlayGone == nil, overlayWindow() == nil { overlayGone = now }
        if gameGone == nil, gameWindow() == nil { gameGone = now }
        usleep(10_000)
    }
    guard gameGone != nil else {
        // The game never left the screen: the switch happened on another display or not at all.
        print(String(format: "  %-30@ skip         Space switch did not move the game's display (overlay gone at %.0f ms)", name as NSString, (overlayGone ?? timeout) * 1000))
        skipped += 1
        return
    }
    let ok = overlayGone != nil
    let lagMs = max(0, Int(((overlayGone ?? timeout) - (gameGone ?? 0)) * 1000))
    let detail = String(format: "overlay gone %.0f ms, game gone %@",
                        (overlayGone ?? timeout) * 1000, gameGone.map { String(format: "%.0f ms", $0 * 1000) } ?? "never (single Space?)")
    results.append(Result(name: name, passed: ok && lagMs <= 50, milliseconds: lagMs, detail: detail))
    print(String(format: "  %-30@ %@ %5d ms  %@", name as NSString, ok && lagMs <= 50 ? "ok  " : "FAIL", lagMs, detail))
}

// MARK: Run

guard gameWindow() != nil || { focusGame(); usleep(800_000); return gameWindow() != nil }() else {
    print("Game window not found (\(gameProcess)). Start the game and SwiftExile first."); exit(1)
}
focusGame(); usleep(800_000)
guard overlayWindow() != nil else { print("SwiftExile overlay not found. Start SwiftExile first."); exit(1) }
print("Title bar height on this macOS: \(Int(titleBarHeight)) pt; game window \(gameWindow()!.bounds)")

for cycle in 1...cycles {
    print("cycle \(cycle)/\(cycles)")
    focusOther()
    measure("app switch away → hidden", overlayHidden)
    focusGame()
    measure("app switch back → aligned", overlayAlignedWithGame)
    if testSpaces {
        pressSpaceShortcut(right: true)
        measureSpaceAway("Space away → gone with game")
        pressSpaceShortcut(right: false)
        usleep(300_000) // Space animation
        focusGame()
        measure("Space back → aligned", overlayAlignedWithGame)
    }
}

let times = results.map(\.milliseconds).sorted()
let failures = results.filter { !$0.passed }
let p95 = times.isEmpty ? 0 : times[min(times.count - 1, Int((Double(times.count) * 0.95).rounded(.up)) - 1)]
print("\nTimes: delay until correct after the switch command (Space away: overlay's delay after the game left the screen).")
print("\(results.count) transitions measured (\(skipped) skipped), \(failures.count) failed; time to correct p50 \(times.isEmpty ? 0 : times[times.count / 2]) ms, p95 \(p95) ms, max \(times.last ?? 0) ms")
print("G1 thresholds: 0 failures, p95 ≤ 500 ms, max ≤ 1500 ms → \(failures.isEmpty && p95 <= 500 && (times.last ?? 0) <= 1500 ? "PASS" : "FAIL")")
for failure in failures { print("  failed: \(failure.name): \(failure.detail)") }
