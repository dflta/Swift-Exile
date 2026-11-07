import Foundation

/// Appends host log lines to `~/Library/Logs/SwiftExile/swiftexile.log`, so a build launched from
/// Finder (no terminal) still leaves a log for bug reports. Rotates to `.1` above `maxBytes`.
public final class LogFile: @unchecked Sendable {
    public let url: URL
    private let maxBytes: UInt64
    private let queue = DispatchQueue(label: "SwiftExile.LogFile")
    private var handle: FileHandle?

    public init(directory: URL = LogFile.defaultDirectory, name: String = "swiftexile.log", maxBytes: UInt64 = 5_000_000) {
        self.url = directory.appendingPathComponent(name)
        self.maxBytes = maxBytes
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SwiftExile", isDirectory: true)
    }

    /// Writes a session header. Call once at launch.
    public func startSession(_ header: String) {
        write("\n===== \(ISO8601DateFormatter().string(from: Date())) \(header) =====\n")
    }

    public func write(_ line: String) {
        let data = Data(line.utf8)
        queue.async { [self] in
            do {
                try openIfNeeded()
                if let handle, (try? handle.offset()) ?? 0 > maxBytes {
                    try rotate()
                }
                try handle?.write(contentsOf: data)
            } catch {
                handle = nil // retry on the next line
            }
        }
    }

    /// Blocks until queued lines are written (tests, shutdown).
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private func openIfNeeded() throws {
        guard handle == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let opened = try FileHandle(forWritingTo: url)
        try opened.seekToEnd()
        handle = opened
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let rotated = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try FileManager.default.moveItem(at: url, to: rotated)
        try openIfNeeded()
    }
}
