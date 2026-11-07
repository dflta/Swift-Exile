import AppKit
import SwiftExileCore
import SwiftUI

extension EnvironmentValues {
    /// The settings the hotkey fields check for hotkeys already in use. Set by the settings pages.
    @Entry var hotkeySettings: OverlaySettingsStore? = nil
}

/// Records a hotkey in Exiled Exchange 2's format ("Ctrl + Shift + D"): click, then press the keys.
/// Esc cancels; Backspace (or Delete) clears it, like upstream's settings. A hotkey another action
/// already uses is refused, with a note saying which one.
struct HotkeyField: View {
    @Binding var hotkey: String?
    /// Record a single key without modifiers (the price check key, whose modifier is chosen apart).
    var keyOnly = false
    var placeholder = "Not set"
    /// The hotkey as the game sees it (the price check key with its hold modifier).
    var effective: (String) -> String = { $0 }

    @Environment(\.hotkeySettings) private var settings

    /// What already uses a hotkey ("Price check"), or nil when it's free.
    private func hotkeyInUse(_ hotkey: String) -> String? {
        settings?.settings?.hotkeyUses()[hotkey]?.joined(separator: ", ")
    }
    @State private var conflict: String?
    @State private var recording = false
    /// A field is recording: SwiftExile's own hotkeys stay off so the keys can be recorded.
    @MainActor static var isRecordingAny = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            if let conflict {
                Text(conflict)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : (hotkey ?? placeholder))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(recording ? Color.accentColor : (hotkey == nil ? .secondary : .primary))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .help(recording ? "Press the keys. Esc cancels, Backspace clears." : "Click, then press the keys")
            if hotkey != nil, !recording {
                Button {
                    hotkey = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        stop()
        conflict = nil
        recording = true
        Self.isRecordingAny = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil // keys pressed while recording don't type anywhere else
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { Self.isRecordingAny = false }
        recording = false
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { // Esc
            stop()
            return
        }
        if (event.keyCode == 51 || event.keyCode == 117) && flags.isDisjoint(with: [.control, .shift, .option]) {
            hotkey = nil // Backspace / Delete clears
            stop()
            return
        }
        guard !flags.contains(.command), let name = KeyNames.byMacKeyCode[event.keyCode] else {
            NSSound.beep() // ⌘ shortcuts and unknown keys can't be game hotkeys
            return
        }
        let recorded = keyOnly ? name : KeyNames.hotkeyString(
            keys: [name], ctrl: flags.contains(.control), shift: flags.contains(.shift), alt: flags.contains(.option))
        if recorded != hotkey, let use = hotkeyInUse(effective(recorded)) {
            NSSound.beep()
            conflict = "\(effective(recorded)) is used by \(use)"
            stop()
            return
        }
        hotkey = recorded
        stop()
    }
}
