import AppKit
import SwiftExileCore
import SwiftUI

/// SwiftExile's settings shown inside the open overlay, over the game, the way Exiled Exchange 2
/// shows its own Settings (opened from the overlay's "⚙ SwiftExile" button). The same pages as the
/// window you get from the menu bar.
@MainActor
final class InOverlaySettingsController {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    let panel: NSPanel
    private let position = PanelPosition(key: "overlaySettingsPosition")
    private var placing = false
    private var lastGame: CGRect?
    /// Keyboard focus moved into or out of the panel (the overlay keeps track of it).
    var onFocusChange: (() -> Void)?
    private var tokens: [NSObjectProtocol] = []

    init(status: HostStatus, actions: AppDelegate) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        // After isFloatingPanel (which resets it); above the overlay it opens from.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        let content = InOverlaySettingsView(status: status, actions: actions, onClose: { [weak self] in self?.hide() })
        panel.contentView = NSHostingView(rootView: content)

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFocusChange?() }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.placing, self.panel.isVisible, let game = self.lastGame else { return }
                self.position.save(frame: self.panel.frame, in: game)
            }
        })
    }

    var isVisible: Bool { panel.isVisible }
    /// Open until closed with ✕, Esc, or ⚙: hidden while the overlay is closed, back when it opens.
    private(set) var isOpen = false

    /// - Parameter game: the game's area (Cocoa coordinates); the panel is centered on it.
    func show(over game: CGRect?) {
        let screen = game ?? NSScreen.main?.visibleFrame ?? .zero
        lastGame = game
        isOpen = true
        let width = min(900, screen.width * 0.85), height = min(640, screen.height * 0.85)
        let size = CGSize(width: width, height: height)
        let origin = position.origin(size: size, in: screen) ?? CGPoint(x: screen.midX - width / 2, y: screen.midY - height / 2)
        placing = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        placing = false
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// Closed by the user.
    func hide() {
        isOpen = false
        suspend()
    }

    /// The overlay closed: hide until it opens again.
    func suspend() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        onFocusChange?()
    }
}

private struct InOverlaySettingsView: View {
    let status: HostStatus
    let actions: AppDelegate
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SwiftExile").font(.headline)
                Text("Settings").font(.headline).foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction) // Esc (a hotkey being recorded takes Esc first)
                .help("Close (Esc)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .dragsWindow() // like a title bar; the position is saved when the panel moves
            Divider()
            SettingsView(status: status, actions: actions)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }
}
