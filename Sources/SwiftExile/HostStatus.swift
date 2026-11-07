import AppKit
import ApplicationServices
import Observation
import SwiftExileCore

/// Live host state shown by the native SwiftUI menu bar item and Settings window.
@MainActor
@Observable
final class HostStatus {
    var serverPort = 0
    var dataDir = ""
    var accessibilityTrusted = AXIsProcessTrusted()

    var gameTitle: String?
    var gameAppName: String?
    var gameFlavor: GameFlavor = .unknown
    var gameRect: CGRect?
    var derivedConfigPath: String?
    var derivedLogPath: String?

    var hotkeysAvailable = false
    var registeredHotkeys: [String] = []

    var gameFocused = false
    var overlayInteractable = false
    var overlayVisible = false

    var isAttached: Bool { gameTitle != nil }

    func attached(_ snapshot: GameWindowTracker.Snapshot) {
        gameTitle = snapshot.title
        gameAppName = snapshot.appName
        gameFlavor = snapshot.flavor
        gameRect = snapshot.contentRect
        derivedConfigPath = snapshot.flavor.derivedConfigPath
        derivedLogPath = snapshot.flavor.derivedClientLogPath
    }

    func detached() {
        gameTitle = nil
        gameAppName = nil
        gameFlavor = .unknown
        gameRect = nil
        derivedConfigPath = nil
        derivedLogPath = nil
        gameFocused = false
        overlayInteractable = false
        overlayVisible = false
    }
}
