import Foundation
import Testing
@testable import SwiftExileCore

@Suite struct GameLogTests {
    /// Collects emitted lines across chunks.
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ new: [String]) { lock.lock(); lines += new; lock.unlock() }
        func take() -> [String] { lock.lock(); defer { lines = []; lock.unlock() }; return lines }
    }

    private func tempFile(_ contents: String = "") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftexile-log-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func splitterKeepsPartialLines() {
        var splitter = LogLineSplitter()
        #expect(splitter.feed(Data("2026/11/07 12:00:00 one\r\n2026/11/07 12:00:01 tw".utf8)) == ["2026/11/07 12:00:00 one"])
        #expect(splitter.feed(Data("o\n\n  \n".utf8)) == ["2026/11/07 12:00:01 two"])
        #expect(splitter.feed(Data("no newline yet".utf8)).isEmpty)
    }

    @Test func splitterHandlesWindowsLineEndings() {
        // Several "\r\n" lines in one read must stay separate lines (they were glued together
        // when splitting on "\n", because Swift treats "\r\n" as a single Character).
        var splitter = LogLineSplitter()
        #expect(splitter.feed(Data("a\r\nb\r\nc\r\n".utf8)) == ["a", "b", "c"])
    }

    @Test func followsFromTheEnd() async throws {
        let url = try tempFile("old line\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let tail = GameLogTail()
        try await tail.start(path: url.path)
        let sink = Sink()
        await tail.readAvailable { sink.add($0) }
        #expect(sink.take().isEmpty) // lines from before the start are skipped, like upstream

        try append("You have entered Clearfell.\nhalf", to: url)
        await tail.readAvailable { sink.add($0) }
        #expect(sink.take() == ["You have entered Clearfell."])
        try append(" a line\n", to: url)
        await tail.readAvailable { sink.add($0) }
        #expect(sink.take() == ["half a line"])
    }

    @Test func rewindRereadsEverything() async throws {
        let url = try tempFile("a\nb\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let tail = GameLogTail()
        try await tail.start(path: url.path)
        #expect(await tail.rewind())
        let sink = Sink()
        await tail.readAvailable { sink.add($0) }
        #expect(sink.take() == ["a", "b"])
    }

    @Test func truncatedFileStartsOver() async throws {
        let url = try tempFile("first session line\nmore\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let tail = GameLogTail()
        try await tail.start(path: url.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("new\n".utf8))
        try handle.close()
        let sink = Sink()
        await tail.readAvailable { sink.add($0) }
        #expect(sink.take() == ["new"])
    }

    @Test func replacedFileStartsOver() async throws {
        let url = try tempFile(String(repeating: "x", count: 100) + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let tail = GameLogTail()
        try await tail.start(path: url.path)
        // A new file at the same path (longer than the old offset, so only the inode tells).
        let replacement = try tempFile(String(repeating: "y", count: 200) + "\nfresh\n")
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        let sink = Sink()
        await tail.readAvailable { sink.add($0) }
        #expect(sink.take() == [String(repeating: "y", count: 200), "fresh"])
    }

    @Test func largeReadsArriveInChunks() async throws {
        let line = String(repeating: "z", count: 99) + "\n"
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let tail = GameLogTail()
        try await tail.start(path: url.path)
        try append(String(repeating: line, count: 2000), to: url) // ~200 KB, several chunks
        let sink = Sink()
        await tail.readAvailable { sink.add($0) }
        #expect(sink.take().count == 2000)
    }

    @Test func pathChoice() {
        let derived = "/wine/Path of Exile 2/logs/Client.txt"
        #expect(GameLogTail.resolvePath(configured: "~/custom.txt", derived: derived, home: "/h", exists: { _ in false }) == NSString("~/custom.txt").expandingTildeInPath)
        #expect(GameLogTail.resolvePath(configured: "", derived: derived, home: "/h", exists: { $0 == derived }) == derived)
        #expect(GameLogTail.resolvePath(configured: nil, derived: nil, home: "/h",
                                        exists: { $0 == "/h/Library/Caches/com.GGG.PathOfExile/Logs/Client.txt" })
                == "/h/Library/Caches/com.GGG.PathOfExile/Logs/Client.txt")
        #expect(GameLogTail.resolvePath(configured: nil, derived: derived, home: "/h", exists: { _ in false }) == nil)
    }

    @Test func dataWriterSessionsAndClientLog() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftexile-data-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = DataFileWriter(dataDir: dir, log: { _ in })

        // Disabled by default: nothing is written.
        await writer.handle(.object(["action": .string("session"), "start": .bool(true), "name": .string("s1"), "header": .string("a,b")]))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("csv-data").path))

        await writer.configure(enabled: true, outputPath: nil)
        await writer.handle(.object(["action": .string("session"), "start": .bool(true), "name": .string("s1"), "header": .string("a,b")]))
        await writer.handle(.object(["action": .string("log-item"), "text": .string("1,2")]))
        await writer.handle(.object(["action": .string("session"), "start": .bool(false)]))
        let csv = try String(contentsOf: dir.appendingPathComponent("csv-data/s1.csv"), encoding: .utf8)
        #expect(csv == "a,b\n1,2\n")

        let event: JSONValue = .object(["ts": .number(1), "type": .string("zone")])
        await writer.handle(.object(["action": .string("client-log-event"), "data": event, "close": .bool(true)]))
        let ndjson = try String(contentsOf: dir.appendingPathComponent("csv-data/client-log.ndjson"), encoding: .utf8)
        #expect(ndjson == #"{"ts":1,"type":"zone"}"# + "\n")
    }
}
