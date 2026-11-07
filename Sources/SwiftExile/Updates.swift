import Foundation
import Observation
import Sparkle

/// Auto-updates through Sparkle (plan §3.4). Updates come from the appcast on GitHub Releases and
/// are accepted only if signed with SwiftExile's EdDSA key (`SUPublicEDKey` in Info.plist).
@MainActor
@Observable
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    private(set) var canCheck = false

    /// Only when running as a bundled app with a feed configured (not `swift run` or debug runs).
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    func start() {
        guard Self.isAvailable, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        canCheck = true
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    // MARK: SPUStandardUserDriverDelegate

    /// SwiftExile is a menu bar app that sits over the game: scheduled update alerts shouldn't
    /// steal focus mid-fight, so Sparkle shows them gently (next time the app is activated).
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
