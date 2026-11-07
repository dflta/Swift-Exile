import Foundation
import Observation
import SwiftExileCore

/// Exiled Exchange 2's settings, edited from SwiftExile's native window.
///
/// Saves to the same `config.json` the overlay uses, tells the overlay (`config-changed`) so its
/// copy stays in sync, and applies the hotkeys right away (computed natively, see
/// `OverlaySettings.hostConfig()`). Changes saved in the overlay flow back here.
@MainActor
@Observable
final class OverlaySettingsStore {
    private(set) var settings: OverlaySettings?
    @ObservationIgnored private var configStore: ConfigStore?
    @ObservationIgnored private var hub: EventHub?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    /// Called with the hotkeys and options derived from the settings after every change.
    @ObservationIgnored var onHostConfig: ((HostConfig) -> Void)?

    func attach(configStore: ConfigStore, hub: EventHub) async {
        self.configStore = configStore
        self.hub = hub
        if let contents = await configStore.load() { settings = OverlaySettings(json: contents) }
    }

    /// The overlay saved its settings (`CLIENT->MAIN::save-config`).
    func savedByOverlay(contents: String) {
        guard let updated = OverlaySettings(json: contents), updated != settings else { return }
        settings = updated
    }

    /// Changes the settings; saved shortly after (typing doesn't rewrite the file on every key).
    func update(_ change: (inout OverlaySettings) -> Void) {
        guard var updated = settings else { return }
        change(&updated)
        guard updated != settings else { return }
        settings = updated
        onHostConfig?(updated.hostConfig())
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func save() {
        guard let settings, let configStore, let hub else { return }
        let contents = settings.serialized()
        Task {
            do {
                try await configStore.save(contents: contents, isTemporary: false)
            } catch {
                await hub.log("error [ConfigStore] Failed to save config: \(error.localizedDescription)")
                return
            }
            if let changed = try? IpcMessage(.configChanged, ConfigChangedPayload(contents: contents)) {
                await hub.send(.broadcast, changed)
            }
        }
    }

    // MARK: Bindings for the window

    /// Problems the hotkeys would have (reserved by the game, used twice), as upstream reports them.
    var hotkeyProblems: [String] {
        guard let settings else { return [] }
        let actions = settings.hostConfig().shortcuts.compactMap(ShortcutAction.init(json:))
        return ShortcutRegistry.build(actions: actions, showModsKey: "Alt").errors.map {
            $0.replacingOccurrences(of: "error [Shortcuts] ", with: "")
        }
    }
}
