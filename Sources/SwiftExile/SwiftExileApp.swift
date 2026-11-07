import SwiftUI

/// Native shell: a menu bar item and a Settings window, both SwiftUI.
/// The game overlay itself is an AppKit panel managed by `OverlayController`.
@main
struct SwiftExileApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(status: appDelegate.status, actions: appDelegate)
        } label: {
            StatusIcon(attached: appDelegate.status.isAttached)
                .background(SettingsOpener(actions: appDelegate))
        }

        Settings {
            SettingsView(status: appDelegate.status, actions: appDelegate)
        }
    }
}

struct MenuBarContent: View {
    let status: HostStatus
    let actions: AppDelegate
    @Environment(\.openSettings) private var openSettings
    @AppStorage(ShortcutController.nativePriceCheckDefaultsKey) private var nativePriceCheck = true

    var body: some View {
        if let title = status.gameTitle {
            Text("Attached to \(title)")
            Text(status.gameFlavor.displayName)
        } else if !status.accessibilityTrusted {
            Text("Accessibility permission needed")
        } else {
            Text("Waiting for Path of Exile 2…")
        }

        Divider()

        Button(status.overlayInteractable ? "Return to Game" : "Show Overlay") {
            actions.toggleOverlay()
        }
        .disabled(!status.isAttached)

        Toggle("Native Price Check (Preview)", isOn: $nativePriceCheck)

        Button("Open in Browser") { actions.openInBrowser() }
        Button("Open Settings Folder") { actions.openDataFolder() }
        Button("Show Log") { actions.openLogFile() }
        if actions.updates.canCheck {
            Button("Check for Updates…") {
                NSApp.activate()
                actions.updates.checkForUpdates()
            }
        }

        Divider()

        Button("Settings…") {
            actions.presentSettings(open: { openSettings() })
        }
        .keyboardShortcut(",")

        Button("Quit SwiftExile") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The menu bar icon: SwiftExile's emblem (Resources/StatusIcon.pdf) as a template image, so macOS
/// tints it for light and dark menu bars. Full strength while attached to the game, dimmed while
/// waiting for it.
struct StatusIcon: View {
    let attached: Bool

    var body: some View {
        Group {
            if let image = attached ? Self.attachedImage : Self.waitingImage {
                Image(nsImage: image)
            } else {
                // Running outside the app bundle (swift run): no PDF resource.
                Image(systemName: attached ? "scope" : "circle.dashed")
            }
        }
        .accessibilityLabel(attached ? "SwiftExile, attached to the game" : "SwiftExile, waiting for the game")
    }

    private static let height: CGFloat = 16

    private static let attachedImage: NSImage? = makeImage(alpha: 1)
    private static let waitingImage: NSImage? = makeImage(alpha: 0.45)

    private static func makeImage(alpha: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "pdf"),
              let source = NSImage(contentsOf: url), source.size.height > 0
        else { return nil }
        let size = NSSize(width: (height * source.size.width / source.size.height).rounded(), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            return true
        }
        image.isTemplate = true // only the alpha channel counts; macOS picks the color
        return image
    }
}

/// SwiftUI only lets a view open the Settings window (`openSettings`). The menu bar icon is always
/// on screen, so it hands that action to the app delegate for other callers (the overlay's button).
private struct SettingsOpener: View {
    let actions: AppDelegate
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { actions.openSettingsAction = { openSettings() } }
    }
}
