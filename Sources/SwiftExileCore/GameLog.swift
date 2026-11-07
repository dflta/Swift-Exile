import Foundation

/// Splits bytes read from the game log into lines. Unlike upstream (which splits each 64 KB chunk
/// on its own), a line cut by a chunk boundary is kept until its end arrives.
public struct LogLineSplitter: Sendable {
    private var pending = Data()

    public init() {}

    /// Complete lines in `bytes` (plus what was pending), trimmed, empty ones dropped
    /// (`GameLogWatcher.ts:146-149`).
    public mutating func feed(_ bytes: Data) -> [String] {
        pending.append(bytes)
        guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = pending[pending.startIndex...lastNewline]
        pending = Data(pending[pending.index(after: lastNewline)...])
        // Split on any line ending: the Windows client writes "\r\n", which Swift treats as one
        // Character, so splitting on "\n" alone would glue every line together.
        return String(decoding: complete, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public mutating func reset() { pending = Data() }
}

/// Port of `GameLogWatcher.ts`: follows the game's `Client.txt` from its current end and reports
/// new lines. Also notices when the file is truncated or replaced (starts over from the top).
public actor GameLogTail {
    public static let chunkSize = 64 * 1024

    public private(set) var path: String?
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var fileID: (device: Int, inode: Int)?
    private var splitter = LogLineSplitter()
    private var isReading = false

    public init() {}

    /// Starts following `path` from its end (only lines written from now on are reported).
    public func start(path: String) throws {
        stop()
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        self.handle = handle
        self.path = path
        offset = try handle.seekToEnd()
        fileID = Self.identity(of: path)
    }

    public func stop() {
        try? handle?.close()
        handle = nil
        path = nil
        offset = 0
        fileID = nil
        splitter.reset()
    }

    /// Read the whole log again from the start (`CLIENT->MAIN::re-parse-log`).
    /// - Returns: false when a read is already running (upstream skips it too).
    public func rewind() -> Bool {
        guard handle != nil, !isReading else { return false }
        offset = 0
        splitter.reset()
        return true
    }

    /// Reads everything new, calling `emit` once per chunk of complete lines.
    public func readAvailable(emit: @Sendable ([String]) async -> Void) async {
        guard let path, !isReading else { return }
        isReading = true
        defer { isReading = false }

        // Rotated (new file at the same path) or truncated: start over from the top.
        let identity = Self.identity(of: path)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
        if let identity, let current = fileID, identity != current {
            try? handle?.close()
            handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            fileID = identity
            offset = 0
            splitter.reset()
        } else if let size, size < offset {
            offset = 0
            splitter.reset()
        }

        guard let handle else { return }
        while true {
            do {
                try handle.seek(toOffset: offset)
                guard let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty else { return }
                offset += UInt64(data.count)
                let lines = splitter.feed(data)
                if !lines.isEmpty { await emit(lines) }
            } catch {
                return
            }
        }
    }

    private static func identity(of path: String) -> (device: Int, inode: Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let device = (attributes[.systemNumber] as? NSNumber)?.intValue,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.intValue
        else { return nil }
        return (device, inode)
    }

    /// Which log to follow: the path set in the overlay's settings, else the one next to the
    /// running game (Wine install folder), else the native client's location.
    public static func resolvePath(configured: String?, derived: String?, home: String = NSHomeDirectory(),
                                   exists: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }) -> String? {
        if let configured, !configured.isEmpty { return (configured as NSString).expandingTildeInPath }
        if let derived, exists(derived) { return derived }
        // Upstream's darwin candidate (GameLogWatcher.ts:28-35), for the native client.
        let native = home + "/Library/Caches/com.GGG.PathOfExile/Logs/Client.txt"
        return exists(native) ? native : nil
    }
}

/// Port of `FileWriter.ts`: `CLIENT->MAIN::write-data` for the library (alpha) feature — item CSV
/// sessions and the parsed client-log ndjson — written under `apt-data/csv-data` by default.
public actor DataFileWriter {
    public enum Channel: String, Sendable { case item, clientLog = "client-log" }

    private var enabled = false
    private var defaultFolder: URL
    private var folder: URL
    private var handles: [Channel: FileHandle] = [:]
    private var lastTimestamp: Double = 0
    private let log: @Sendable (String) -> Void

    public init(dataDir: URL, log: @escaping @Sendable (String) -> Void) {
        defaultFolder = dataDir.appendingPathComponent("csv-data", isDirectory: true)
        folder = defaultFolder
        self.log = log
    }

    public func configure(enabled: Bool, outputPath: String?) {
        self.enabled = enabled
        if let outputPath, !outputPath.isEmpty {
            folder = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            folder = defaultFolder
        }
    }

    public var outputFolder: URL { folder }

    /// Handles one `write-data` payload (`action`: "log-item", "session", "client-log-event").
    public func handle(_ payload: JSONValue) {
        guard enabled, case .object(let fields) = payload, case .string(let action)? = fields["action"] else { return }
        switch action {
        case "client-log-event":
            guard let data = fields["data"] else { return }
            if handles[.clientLog] == nil {
                open(.clientLog, file: folder.appendingPathComponent("client-log.ndjson"), overwrite: true)
            }
            if case .object(let event) = data, case .number(let ts)? = event["ts"] {
                if ts < lastTimestamp { log("warn [FileWriter] time just went backwards: \(ts) < \(lastTimestamp)") }
                lastTimestamp = ts
            }
            write(Self.jsonLine(data), to: .clientLog)
            if case .bool(true)? = fields["close"] { close(.clientLog) }
        case "log-item":
            guard case .string(let text)? = fields["text"] else { return }
            write(text, to: .item)
        case "session":
            if case .bool(true)? = fields["start"] {
                guard case .string(let name)? = fields["name"], case .string(let header)? = fields["header"], !name.isEmpty else {
                    log("error [FileWriter] Invalid session start event.")
                    return
                }
                // The name becomes a file name: no path separators.
                let safeName = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
                let file = folder.appendingPathComponent(safeName + ".csv")
                if open(.item, file: file, overwrite: false) { write(header, to: .item) }
            } else {
                close(.item)
            }
        default:
            return
        }
    }

    /// Closes the client-log channel (before a re-parse, `flushClientLogFile`).
    public func flushClientLog() {
        if handles[.clientLog] != nil { close(.clientLog) }
    }

    /// Opens `file` for appending (or overwriting). Returns true when the file is new.
    @discardableResult
    private func open(_ channel: Channel, file: URL, overwrite: Bool) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let isNew = overwrite || !FileManager.default.fileExists(atPath: file.path)
            if isNew {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            if isNew { try handle.truncate(atOffset: 0) } else { try handle.seekToEnd() }
            handles[channel]?.closeFile()
            handles[channel] = handle
            return isNew
        } catch {
            log("error [FileWriter] Failed to open \(file.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    private func write(_ line: String, to channel: Channel) {
        guard let handle = handles[channel] else {
            log("error [FileWriter] Unable to write to channel \(channel.rawValue), channel closed.")
            return
        }
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func close(_ channel: Channel) {
        guard let handle = handles.removeValue(forKey: channel) else {
            log("error [FileWriter] Channel \(channel.rawValue) already closed.")
            return
        }
        try? handle.close()
        log("info [FileWriter] Channel \(channel.rawValue) closed.")
    }

    private static func jsonLine(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
