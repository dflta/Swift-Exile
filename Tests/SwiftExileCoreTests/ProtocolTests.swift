import Foundation
import Testing
@testable import SwiftExileCore

@Suite struct ProtocolTests {
    @Test func payloadlessEventOmitsPayloadKey() throws {
        let text = try IpcMessage(.overlayAttached).jsonString()
        #expect(text == #"{"name":"MAIN->OVERLAY::overlay-attached"}"#)
    }

    @Test func parsesEventWithoutPayload() throws {
        let message = try IpcMessage.parse(#"{"name":"OVERLAY->MAIN::focus-game"}"#)
        #expect(message.eventName == .focusGame)
        #expect(message.payload == nil)
    }

    @Test func roundTripsTypedPayload() throws {
        let text = #"{"name":"CLIENT->MAIN::save-config","payload":{"contents":"{\"a\":1}","isTemporary":false}}"#
        let message = try IpcMessage.parse(text)
        let payload = try #require(try message.payload?.decode(SaveConfigPayload.self))
        #expect(payload.contents == #"{"a":1}"#)
        #expect(payload.isTemporary == false)
    }

    @Test func hostStateKeepsNullContents() throws {
        let data = try JSONEncoder().encode(HostState(contents: nil, version: "v", updater: .initial))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.keys.contains("contents"))
        #expect(object["contents"] is NSNull)
        #expect((object["updater"] as? [String: Any])?["state"] as? String == "initial")
    }

    @Test func eventNamesAreUnique() {
        let names = IpcEventName.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
        #expect(names.count == 20)
    }
}

@Suite struct ConfigStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test func loadReturnsNilWhenMissing() async {
        let store = ConfigStore(dataDir: tempDir())
        #expect(await store.load() == nil)
    }

    @Test func saveThenLoad() async throws {
        let store = ConfigStore(dataDir: tempDir())
        try await store.save(contents: "{\"x\":1}", isTemporary: false)
        #expect(await store.load() == "{\"x\":1}")
    }

    @Test func temporarySaveIsSticky() async throws {
        let dir = tempDir()
        let store = ConfigStore(dataDir: dir)
        try await store.save(contents: "real", isTemporary: false)
        try await store.save(contents: "tmp1", isTemporary: true)
        try await store.save(contents: "tmp2", isTemporary: false) // still goes to .tmp
        #expect(try String(contentsOf: dir.appendingPathComponent("config.json"), encoding: .utf8) == "real")
        #expect(try String(contentsOf: dir.appendingPathComponent("config.json.tmp"), encoding: .utf8) == "tmp2")
    }

    @Test func readOnlyStoreNeverWrites() async throws {
        let dir = tempDir()
        let store = ConfigStore(dataDir: dir, readOnly: true)
        try await store.save(contents: "x", isTemporary: false)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path))
    }
}

@Suite struct ProxyRulesTests {
    @Test func allowlistedTargetKeepsPathAndQuery() throws {
        let target = try #require(HttpProxy.target(forRequestURI: "/proxy/www.pathofexile.com/api/trade2/data/leagues?realm=poe2"))
        #expect(target.host == "www.pathofexile.com")
        #expect(target.url.absoluteString == "https://www.pathofexile.com/api/trade2/data/leagues?realm=poe2")
    }

    @Test func rejectsUnknownHost() {
        #expect(HttpProxy.target(forRequestURI: "/proxy/evil.example.com/x") == nil)
        #expect(HttpProxy.target(forRequestURI: "/proxy/www.pathofexile.com.evil.com/x") == nil)
    }

    @Test func requestHeaderFilter() {
        #expect(!HttpProxy.shouldForwardRequestHeader("sec-fetch-mode"))
        #expect(!HttpProxy.shouldForwardRequestHeader("origin"))
        #expect(!HttpProxy.shouldForwardRequestHeader("content-length"))
        #expect(!HttpProxy.shouldForwardRequestHeader("accept-encoding"))
        #expect(HttpProxy.shouldForwardRequestHeader("content-type"))
        #expect(HttpProxy.shouldForwardRequestHeader("accept"))
    }

    @Test func responseHeaderFilterKeepsRateLimitHeaders() {
        #expect(!HttpProxy.shouldForwardResponseHeader("content-encoding"))
        #expect(!HttpProxy.shouldForwardResponseHeader("content-length"))
        #expect(HttpProxy.shouldForwardResponseHeader("x-rate-limit-ip"))
        #expect(HttpProxy.shouldForwardResponseHeader("content-type"))
    }
}
