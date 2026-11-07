import AppKit
import CoreGraphics
import SwiftExileCore

/// One active session event tap for global hotkeys and pointer tracking (plan §2.3).
/// Replaces uiohook-napi and Electron's globalShortcut.
@MainActor
final class InputTap {
    /// Stamped on events SwiftExile posts itself, so the tap never reacts to them.
    nonisolated static let syntheticMarker: Int64 = 0x5357_4558 // "SWEX"

    struct KeyEvent: Sendable {
        enum Kind: Sendable { case down, up, flagsChanged }
        var kind: Kind
        var keyCode: UInt16
        var ctrl: Bool
        var shift: Bool
        var alt: Bool
        var command: Bool
        var isRepeat: Bool
    }

    struct PointerEvent: Sendable {
        enum Kind: Sendable { case moved, down }
        var kind: Kind
        /// Global coordinates, origin at the top-left of the main display (same as AX frames).
        var location: CGPoint
        var ctrl: Bool
        var alt: Bool
    }

    /// Return true to swallow the event (it then never reaches the game).
    var onKey: ((KeyEvent) -> Bool)?
    var onPointer: ((PointerEvent) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var reenableCount = 0
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    var isRunning: Bool { tap != nil }

    /// Creates the tap. Fails when macOS hasn't granted permission (Accessibility; possibly Input Monitoring).
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDragged,
                                    .rightMouseDragged, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: inputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    /// macOS disables a tap whose callback is too slow or on some user input; turn it back on.
    fileprivate func reenable(reason: CGEventType) {
        guard let tap else { return }
        reenableCount += 1
        CGEvent.tapEnable(tap: tap, enable: true)
        log("warn [InputTap] tap was disabled (\(reason == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabled (\(reenableCount) so far)")
    }

    fileprivate func handleKey(_ event: KeyEvent) -> Bool { onKey?(event) ?? false }
    fileprivate func handlePointer(_ event: PointerEvent) { onPointer?(event) }
}

/// Runs on the main run loop (the source was added there). Extract plain values first, then
/// hop into main-actor code; only a Bool comes back.
private func inputTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { tap.reenable(reason: type) }
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == InputTap.syntheticMarker {
        return Unmanaged.passUnretained(event)
    }

    let flags = event.flags
    let ctrl = flags.contains(.maskControl)
    let alt = flags.contains(.maskAlternate)
    switch type {
    case .keyDown, .keyUp, .flagsChanged:
        let keyEvent = InputTap.KeyEvent(
            kind: type == .keyDown ? .down : (type == .keyUp ? .up : .flagsChanged),
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            ctrl: ctrl,
            shift: flags.contains(.maskShift),
            alt: alt,
            command: flags.contains(.maskCommand),
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
        let swallow = MainActor.assumeIsolated { tap.handleKey(keyEvent) }
        return swallow ? nil : Unmanaged.passUnretained(event)
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown:
        let isDown = type == .leftMouseDown || type == .rightMouseDown
        let pointer = InputTap.PointerEvent(kind: isDown ? .down : .moved, location: event.location, ctrl: ctrl, alt: alt)
        MainActor.assumeIsolated { tap.handlePointer(pointer) }
        return Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}

/// Posts key events into the system (replaces uiohook's keyToggle/keyTap).
@MainActor
final class KeySynthesizer {
    private let source = CGEventSource(stateID: .privateState)
    private var heldModifiers: Set<String> = []

    func post(_ steps: [KeyStep]) {
        for step in steps { post(step) }
    }

    func tap(_ key: String) {
        post([KeyStep(key, down: true), KeyStep(key, down: false)])
    }

    private func post(_ step: KeyStep) {
        guard let code = KeyNames.macKeyCode(for: step.key),
              let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: step.down)
        else { return }
        let isModifier = KeyNames.isModifier(step.key)
        if isModifier {
            if step.down { heldModifiers.insert(step.key) } else { heldModifiers.remove(step.key) }
            event.type = .flagsChanged
        }
        // Explicit flags on every event: the game (and Wine) read modifiers from the event.
        var flags: CGEventFlags = []
        if heldModifiers.contains("Ctrl") { flags.insert(.maskControl) }
        if heldModifiers.contains("Alt") { flags.insert(.maskAlternate) }
        if heldModifiers.contains("Shift") { flags.insert(.maskShift) }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: InputTap.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }
}

/// `NSPasteboard.general` behind the poller's protocol.
struct SystemPasteboard: PasteboardAccess {
    func readString() async -> String? {
        await MainActor.run { NSPasteboard.general.string(forType: .string) }
    }

    func writeString(_ value: String) async {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }
}
