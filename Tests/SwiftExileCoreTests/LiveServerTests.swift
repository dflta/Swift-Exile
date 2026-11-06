import Foundation
import Testing
@testable import SwiftExileCore

/// End-to-end over a real socket: the same path the renderer uses (`IPC.ts:25`, `ws://<host>/events`).
@Suite struct LiveServerTests {
    @Test func saveConfigOverWebSocketWritesFileAndBroadcasts() async throws {
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let hub = EventHub()
        let store = ConfigStore(dataDir: dataDir)
        // Same wiring as the app's save-config handler.
        await hub.on(.saveConfig) { payload in
            guard let save = try? payload?.decode(SaveConfigPayload.self) else { return }
            try? await store.save(contents: save.contents, isTemporary: save.isTemporary)
            if let changed = try? IpcMessage(.configChanged, ConfigChangedPayload(contents: save.contents)) {
                await hub.send(.broadcast, changed)
            }
        }
        await hub.log("info hello from host")

        let port = try await HostServer.start(
            configuration: HostServerConfiguration(
                rendererDir: nil, dataDir: dataDir, version: "live", proxyUserAgent: "test"),
            hub: hub, configStore: store)
        #expect(port > 0)

        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/events")!)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        // 1. History arrives first.
        let first = try await receiveMessage(socket)
        #expect(first.eventName == .logEntry)
        #expect(try first.payload?.decode(LogEntryPayload.self).message.contains("hello from host") == true)

        // 2. save-config → file on disk + config-changed broadcast.
        let save = #"{"name":"CLIENT->MAIN::save-config","payload":{"contents":"{\"configVersion\":42}","isTemporary":false}}"#
        try await socket.send(.string(save))
        let changed = try await receiveMessage(socket)
        #expect(changed.eventName == .configChanged)
        #expect(try changed.payload?.decode(ConfigChangedPayload.self).contents == #"{"configVersion":42}"#)
        #expect(try String(contentsOf: dataDir.appendingPathComponent("config.json"), encoding: .utf8) == #"{"configVersion":42}"#)

        // 3. GET /config now returns it.
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/config")!)
        #expect(String(decoding: data, as: UTF8.self).contains(#"{\"configVersion\":42}"#))
    }

    private func receiveMessage(_ socket: URLSessionWebSocketTask) async throws -> IpcMessage {
        switch try await socket.receive() {
        case .string(let text): return try IpcMessage.parse(text)
        case .data(let data): return try IpcMessage.parse(String(decoding: data, as: UTF8.self))
        @unknown default: throw CancellationError()
        }
    }
}
