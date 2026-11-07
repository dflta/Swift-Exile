import Foundation
import SwiftExileCore

/// Port of the host side of upstream's client-log features (`GameLogWatcher.ts`, `FileWriter.ts`):
/// sends new lines of the game's `Client.txt` to the overlay (`MAIN->CLIENT::game-log`), re-reads it
/// on `CLIENT->MAIN::re-parse-log`, and writes the library feature's data files.
/// Reading the log is opt-in in the overlay's settings ("readClientLog"), as upstream.
@MainActor
final class GameLogController {
    private let hub: EventHub
    private let status: HostStatus
    private let tail = GameLogTail()
    let writer: DataFileWriter
    private var timer: Timer?
    /// The overlay's "Allow reading of Client.txt file" (lines are sent to the web overlay).
    private var overlayReads = false
    /// SwiftExile's native experience tracker (Settings ▸ Leveling) also needs the log.
    private(set) var nativeTracker = UserDefaults.standard.bool(forKey: GameLogController.nativeTrackerKey)
    static let nativeTrackerKey = "nativeExperienceTracker"
    private var enabled: Bool { overlayReads || nativeTracker }
    /// The native tracker's state, updated from the log.
    let leveling = LevelingModel()
    private var configuredPath: String?
    private var followedPath: String?

    init(hub: EventHub, status: HostStatus, dataDir: URL) {
        self.hub = hub
        self.status = status
        writer = DataFileWriter(dataDir: dataDir, log: { line in Task { await hub.log(line) } })
    }

    func hostConfigChanged(_ config: HostConfig) {
        let writer = writer
        Task { await writer.configure(enabled: config.libraryAlpha, outputPath: config.libraryOutputPath) }
        overlayReads = config.readClientLog
        configuredPath = config.clientLog
        restart()
    }

    /// The derived log path changes with the game (Wine install folder), so re-check on attach.
    func gameAttached() {
        restart()
    }

    /// - Parameter save: false at startup (the value came from the saved setting, or from a
    ///   launch argument that shouldn't become permanent).
    func setNativeTracker(_ on: Bool, save: Bool = true) {
        nativeTracker = on
        if save { UserDefaults.standard.set(on, forKey: Self.nativeTrackerKey) }
        // Already following for the overlay: just catch the tracker up from the log's history.
        if on, let followedPath { seedHistory(path: followedPath) }
        restart()
    }

    var followedLog: String? { followedPath }

    func reparse() {
        let tail = tail, writer = writer, hub = hub
        let deliver = makeDeliver()
        Task {
            await writer.flushClientLog()
            if await tail.rewind() {
                await hub.log("info [GameLogWatcher] re-parsing the whole log")
                await tail.readAvailable(emit: deliver)
            } else {
                await hub.log("warn [GameLogWatcher] Asked to re-parse log but currently reading, skipping")
            }
        }
    }

    private func restart() {
        guard enabled else {
            if followedPath != nil {
                log("info [GameLogWatcher] disabled")
                stop()
            }
            return
        }
        guard let path = GameLogTail.resolvePath(configured: configuredPath, derived: status.derivedLogPath) else {
            if followedPath == nil {
                if status.isAttached {
                    log("error [GameLogWatcher] No log file found. Set the log file in the overlay's settings.")
                } else {
                    log("info [GameLogWatcher] waiting for the game to find its log file")
                }
            }
            return
        }
        guard path != followedPath else { return }
        stop()
        let tail = tail
        Task { [weak self] in
            do {
                try await tail.start(path: path)
                self?.followedPath = path
                self?.startTimer()
                self?.log("info [GameLogWatcher] following \(path)")
                if self?.nativeTracker == true { self?.seedHistory(path: path) }
            } catch {
                self?.log("error [GameLogWatcher] Failed to watch file: \(error.localizedDescription)")
            }
        }
    }

    /// Starts the native tracker from the log's history (your level and current zone).
    private func seedHistory(path: String) {
        Task { [weak self] in
            let history = await Task.detached { LevelingState.fromHistory(path: path) }.value
            self?.leveling.state = history
            let area = history.areaLevel.map(String.init) ?? "unknown"
            self?.log("info [Leveling] from the log: level \(history.playerLevel.map(String.init) ?? "unknown"), area level \(area)")
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        followedPath = nil
        let tail = tail
        Task { await tail.stop() }
    }

    /// Same interval as upstream's `watchFile(..., { interval: 450 })`.
    private func startTimer() {
        timer?.invalidate()
        let tail = tail
        let deliver = makeDeliver()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { _ in
            Task { await tail.readAvailable(emit: deliver) }
        }
    }

    /// New lines go to the native tracker, and to the web overlay only if it was allowed to read
    /// the log there (upstream's opt-in).
    private func makeDeliver() -> @Sendable ([String]) async -> Void {
        let hub = hub
        return { [weak self] lines in
            let sendToOverlay = await MainActor.run { () -> Bool in
                guard let self else { return false }
                if self.nativeTracker { self.leveling.state.apply(lines: lines) }
                return self.overlayReads
            }
            guard sendToOverlay, let message = try? IpcMessage(.gameLog, GameLogPayload(lines: lines)) else { return }
            await hub.send(.broadcast, message)
        }
    }

    private func log(_ line: String) {
        let hub = hub
        Task { await hub.log(line) }
    }
}

/// `MAIN->CLIENT::game-log` payload.
struct GameLogPayload: Codable, Sendable {
    var lines: [String]
}
