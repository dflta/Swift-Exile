import Foundation
import Testing
@testable import SwiftExileCore

@Suite struct LogFileTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test func appendsLines() throws {
        let log = LogFile(directory: tempDir())
        log.startSession("SwiftExile test")
        log.write("[12:00:00] info one\n")
        log.write("[12:00:01] info two\n")
        log.flush()
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(text.contains("===== "))
        #expect(text.contains("SwiftExile test"))
        #expect(text.hasSuffix("info one\n[12:00:01] info two\n"))
    }

    @Test func rotatesWhenTooLarge() throws {
        let dir = tempDir()
        let log = LogFile(directory: dir, maxBytes: 100)
        for index in 0..<20 { log.write("line \(index) with some padding text\n") }
        log.flush()
        let rotated = dir.appendingPathComponent("swiftexile.log.1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        let current = try String(contentsOf: log.url, encoding: .utf8)
        #expect(current.contains("line 19"))
        #expect(!current.contains("line 0 "))
    }
}
