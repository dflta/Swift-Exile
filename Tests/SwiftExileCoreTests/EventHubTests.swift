import Foundation
import Testing
@testable import SwiftExileCore

/// Routing rules from upstream `main/src/server.ts:58-117`.
@Suite struct EventHubTests {
    private func makeHub() -> EventHub {
        EventHub(clock: { "12:00:00" })
    }

    private func next(_ iterator: inout AsyncStream<String>.Iterator) async throws -> IpcMessage {
        let text = try #require(await iterator.next())
        return try IpcMessage.parse(text)
    }

    @Test func newClientReceivesLogHistoryFirst() async throws {
        let hub = makeHub()
        await hub.log("info hello")
        let (_, stream) = await hub.connect()
        var iterator = stream.makeAsyncIterator()
        let first = try await next(&iterator)
        #expect(first.eventName == .logEntry)
        #expect(try first.payload?.decode(LogEntryPayload.self).message == "[12:00:00] info hello\n")
    }

    @Test func newestClientIsLastActive() async throws {
        let hub = makeHub()
        let (first, _) = await hub.connect()
        #expect(await hub.lastActiveClient == first)
        let (second, _) = await hub.connect()
        #expect(await hub.lastActiveClient == second)
    }

    @Test func usedRecentlySwitchesLastActive() async throws {
        let hub = makeHub()
        let (first, firstStream) = await hub.connect()
        let (second, _) = await hub.connect()
        await hub.receive(from: first, text: #"{"name":"CLIENT->MAIN::used-recently","payload":{"isOverlay":false}}"#)
        #expect(await hub.lastActiveClient == first)

        var iterator = firstStream.makeAsyncIterator()
        _ = try await next(&iterator) // log history
        await hub.send(.lastActive, IpcMessage(.overlayAttached))
        #expect(try await next(&iterator).eventName == .overlayAttached)
        _ = second
    }

    @Test func disconnectLeavingOneClientEmitsSyntheticUsedRecently() async throws {
        let hub = makeHub()
        let received = Received()
        await hub.on(.usedRecently) { payload in
            await received.append(try? payload?.decode(UsedRecentlyPayload.self).isOverlay)
        }
        let (first, _) = await hub.connect()
        let (second, _) = await hub.connect()
        await hub.disconnect(second)
        #expect(await hub.lastActiveClient == first)
        #expect(await received.values == [true])
    }

    @Test func disconnectWithSeveralLeftFallsBackToNewest() async throws {
        let hub = makeHub()
        let (a, _) = await hub.connect()
        let (b, _) = await hub.connect()
        let (c, _) = await hub.connect()
        await hub.receive(from: b, text: #"{"name":"CLIENT->MAIN::used-recently","payload":{"isOverlay":true}}"#)
        await hub.disconnect(b)
        #expect(await hub.lastActiveClient == c)
        _ = a
    }

    @Test func broadcastReachesEveryClient() async throws {
        let hub = makeHub()
        let (_, s1) = await hub.connect()
        let (_, s2) = await hub.connect()
        await hub.send(.broadcast, try IpcMessage(.configChanged, ConfigChangedPayload(contents: "{}")))
        for stream in [s1, s2] {
            var iterator = stream.makeAsyncIterator()
            _ = try await next(&iterator) // log history
            #expect(try await next(&iterator).eventName == .configChanged)
        }
    }

    @Test func handlersReceivePayloads() async throws {
        let hub = makeHub()
        let received = Received()
        await hub.on(.saveConfig) { payload in
            await received.append(try? payload?.decode(SaveConfigPayload.self).isTemporary)
        }
        let (id, _) = await hub.connect()
        await hub.receive(from: id, text: #"{"name":"CLIENT->MAIN::save-config","payload":{"contents":"{}","isTemporary":true}}"#)
        #expect(await received.values == [true])
    }
}

private actor Received {
    var values: [Bool?] = []
    func append(_ value: Bool?) { values.append(value) }
}
