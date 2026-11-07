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
            Image(systemName: appDelegate.status.isAttached ? "scope" : "circle.dashed")
                .accessibilityLabel("SwiftExile")
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

        Button("Open in Browser") { actions.openInBrowser() }
        Button("Open Settings Folder") { actions.openDataFolder() }

        Divider()

        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Quit SwiftExile") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
