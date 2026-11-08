import AppKit
import SwiftUI

/// A short notice over the game: SwiftExile's "ready" notice when it finds the game (in place of
/// Exiled Exchange 2's, LoadingAnimation.vue), and "waiting for Wine's clipboard" while a stash
/// search waits. Click-through; fades out by itself.
@MainActor
final class NoticeController {
    struct Notice {
        var title: String
        var message: String
        /// A spinner instead of the app icon.
        var showsProgress = false
    }

    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 72),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1) // after isFloatingPanel
    }

    /// Shows the notice centered over the game, a fifth of the way up.
    /// - Parameter game: the game's area, Cocoa coordinates.
    func show(_ notice: Notice, over game: CGRect, for seconds: TimeInterval) {
        let hosting = NSHostingView(rootView: NoticeView(notice: notice))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        let size = hosting.fittingSize
        panel.setFrame(NSRect(x: (game.midX - size.width / 2).rounded(), y: (game.minY + game.height * 0.2).rounded(),
                              width: size.width, height: size.height), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self.panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
                                                 MainActor.assumeIsolated {
                                                     guard let self, self.hideWork == nil else { return }
                                                     self.panel.orderOut(nil)
                                                 }
                                             })
    }

    /// Renders a notice to a PNG (development checks).
    func snapshot(_ notice: Notice, to url: URL) -> Bool {
        let view = NSHostingView(rootView: NoticeView(notice: notice))
        view.setFrameSize(view.fittingSize)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: 0), size: view.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
    }
}

extension NoticeController.Notice {
    static let ready = Self(title: "SwiftExile", message: "Ready and running in the background")
    static let clipboardWait = Self(title: "Waiting for Wine's clipboard",
                                    message: "It takes about 2 seconds", showsProgress: true)
}

private struct NoticeView: View {
    let notice: NoticeController.Notice

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if notice.showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(nsImage: NSApp.applicationIconImage).resizable()
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(.system(size: 13, weight: .bold))
                Text(notice.message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .glassBackground(cornerRadius: 20)
        .fixedSize()
    }
}

extension View {
    /// Liquid Glass on macOS 26 and later, a material before it.
    @ViewBuilder
    func glassBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}
