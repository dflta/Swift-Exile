import AppKit
import SwiftExileCore
import SwiftUI

/// SwiftExile's own bar in the open overlay, next to Exiled Exchange 2's widget menu: settings, stash
/// searches, the experience tracker, and a paste-to-price-check field. Drag it by the grab tab on its
/// left; the position is remembered relative to the game window.
@MainActor
final class OverlayBarController {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true } // the paste field needs keyboard focus
        override var canBecomeMain: Bool { false }
    }

    let panel: NSPanel
    private let status: HostStatus
    private var tokens: [NSObjectProtocol] = []
    private var placing = false
    private var handle: FloatingHandle?
    var onFocusChange: (() -> Void)?

    private let position = PanelPosition(key: "overlayBarPosition")

    init(status: HostStatus, actions: AppDelegate) {
        self.status = status
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 44),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true // buttons work without taking focus; the text field takes it
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        let hosting = NSHostingView(rootView: OverlayBarView(actions: actions))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFocusChange?() }
            })
        }
        handle = FloatingHandle(attachedTo: panel)
        tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.remember() }
        })
    }

    func show() {
        guard let game = status.gameRect else { return }
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        // Default: top center of the game, below where Exiled Exchange 2's menu usually sits.
        let origin = position.origin(size: size, in: game)
            ?? CGPoint(x: game.midX - size.width / 2, y: game.maxY - game.height * 0.06 - size.height)
        placing = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        placing = false
        panel.orderFrontRegardless()
        handle?.setShown(true)
    }

    func hide() {
        guard panel.isVisible else { return }
        handle?.setShown(false)
        panel.orderOut(nil)
        onFocusChange?()
    }

    /// Saves where the user dragged it, as a fraction of the game area (survives resolution changes).
    private func remember() {
        guard !placing, panel.isVisible, let game = status.gameRect else { return }
        position.save(frame: panel.frame, in: game)
    }
}

private struct OverlayBarView: View {
    let actions: AppDelegate
    @AppStorage(GameLogController.nativeTrackerKey) private var tracker = false
    @State private var pasted = ""
    @State private var showSearches = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                actions.openSettingsFromOverlay()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("SwiftExile settings")
            Button {
                showSearches.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Stash searches")
            .popover(isPresented: $showSearches, arrowEdge: .bottom) {
                StashSearchMenu(store: actions.overlaySettings) { text in
                    showSearches = false
                    actions.runStashSearch(text)
                }
            }
            Toggle("XP", isOn: Binding(get: { tracker }, set: { on in
                tracker = on
                actions.experienceTrackerChanged(on)
            }))
            .toggleStyle(.button)
            .help("Experience tracker")
            TextField("Price check", text: $pasted, prompt: Text("Price check (⌘V)"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 150)
                .onChange(of: pasted) { _, text in
                    guard ItemTextDetector.isItem(text) else { return }
                    pasted = ""
                    actions.priceCheckPasted(text)
                }
                .help("Paste copied item text to price check it")
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

/// The saved stash searches, for running one from the bar.
private struct StashSearchMenu: View {
    let store: OverlaySettingsStore
    let onRun: (String) -> Void

    var body: some View {
        let entries = (store.settings?.widgets("stash-search") ?? [])
            .compactMap { OverlaySettings.number($0["wmId"]) }
            .flatMap { store.settings?.stashSearchEntries(widgetID: $0) ?? [] }
            .filter { !$0.text.isEmpty }
        VStack(alignment: .leading, spacing: 2) {
            if entries.isEmpty {
                Text("No stash searches yet. Add them in SwiftExile's settings ▸ Stash Search.")
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                Button {
                    onRun(entry.text)
                } label: {
                    HStack {
                        Text(entry.name.isEmpty ? entry.text : entry.name).lineLimit(1)
                        Spacer(minLength: 12)
                        if let hotkey = entry.hotkey { Text(hotkey).foregroundStyle(.secondary).font(.caption) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(minWidth: 240, alignment: .leading)
        .frame(maxHeight: 360)
    }
}
