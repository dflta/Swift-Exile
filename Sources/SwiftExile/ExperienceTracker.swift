import AppKit
import Observation
import SwiftExileCore
import SwiftUI

/// State of the native experience tracker, fed by `GameLogController`.
@MainActor
@Observable
final class LevelingModel {
    var state = LevelingState()
    /// The overlay is open: a grab tab shows beside the panel to move it.
    var movable = false
}

/// Native replacement for Exiled Exchange 2's XP widget: a small click-through panel above the
/// game's experience bar showing your level, the experience you get in the current area, and how
/// far "over" the ideal area level you are. Shown only while the game is in front.
@MainActor
final class ExperienceTrackerController {
    private let panel: NSPanel
    private let status: HostStatus
    private let model: LevelingModel
    private var timer: Timer?
    private let position = PanelPosition(key: "experienceTrackerPosition")
    private var placing = false
    private var moveToken: NSObjectProtocol?
    private var handle: FloatingHandle?
    var isEnabled = false { didSet { update() } }

    init(model: LevelingModel, status: HostStatus) {
        self.model = model
        self.status = status
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 30),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true // never in the way of clicks in the game
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        // After isFloatingPanel (which resets it); one above the overlay so the open overlay never covers it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        let hosting = NSHostingView(rootView: ExperienceTrackerView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        // Cheap position/visibility check; the game window can move or lose focus at any time.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        handle = FloatingHandle(attachedTo: panel)
        moveToken = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.placing, self.model.movable, let game = self.status.gameRect else { return }
                self.position.save(frame: self.panel.frame, in: game)
            }
        }
    }

    /// The open overlay appeared or went away: the panel can be moved only while it's open.
    func overlayOpenChanged(_ open: Bool) {
        model.movable = open
        panel.ignoresMouseEvents = !open
        update()
    }

    private func update() {
        // Visible over the game and over the open overlay (where Exiled Exchange 2's XP widget was),
        // not when another app is in front (the overlay is then hidden even if it was open).
        let gameOrOverlay = status.gameFocused || (status.overlayInteractable && status.overlayVisible)
        guard isEnabled, gameOrOverlay, let gameCocoa = status.gameRect, model.state.playerLevel != nil || model.state.areaLevel != nil else {
            handle?.setShown(false)
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        // Upstream's anchor for its XP widget: bottom center at 68 % across, 98 % down the game,
        // unless you moved it.
        let anchorX = gameCocoa.minX + gameCocoa.width * 0.68
        let anchorY = gameCocoa.minY + gameCocoa.height * 0.02 // Cocoa: from the bottom
        let origin = position.origin(size: size, in: gameCocoa) ?? CGPoint(x: (anchorX - size.width / 2).rounded(), y: anchorY.rounded())
        let frame = NSRect(origin: origin, size: size)
        // Don't fight a drag in progress.
        if panel.frame.size != frame.size || (!model.movable && panel.frame.origin != frame.origin) {
            placing = true
            panel.setFrame(frame, display: true)
            placing = false
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        // The grab tab sits beside the panel while the overlay is open, so the panel itself never
        // changes size when it appears.
        if model.movable != (handle?.isShown ?? false) { handle?.setShown(model.movable) }
    }
}

struct ExperienceTrackerView: View {
    let model: LevelingModel

    var body: some View {
        let state = model.state
        HStack(spacing: 10) {
            labeled("Lv", state.playerLevel.map(String.init) ?? "?")
            labeled("Area", state.areaLevel.map(String.init) ?? "?")
            if let penalty = state.penalty {
                labeled("Exp", penalty >= 99.95 ? "100%" : String(format: "%.1f%%", penalty))
                    .foregroundStyle(penalty >= 99.95 ? Color.green : (penalty >= 70 ? Color.orange : Color.red))
            }
            if let over = state.over {
                labeled("Over", String(over))
                    .foregroundStyle(over < 0 ? Color.orange : .primary)
            }
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary).fontWeight(.medium)
            Text(value)
        }
    }
}
