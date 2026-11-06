import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import SwiftExileCore

@Suite struct HostServerTests {
    private struct Fixture {
        let dataDir: URL
        let rendererDir: URL
        let app: Application<RouterResponder<BasicRequestContext>>
        let configStore: ConfigStore
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataDir = root.appendingPathComponent("apt-data", isDirectory: true)
        let rendererDir = root.appendingPathComponent("renderer", isDirectory: true)
        try FileManager.default.createDirectory(at: rendererDir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try "<html>ok</html>".write(to: rendererDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "console.log(1)".write(to: rendererDir.appendingPathComponent("assets/app.js"), atomically: true, encoding: .utf8)
        try "secret".write(to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)

        let configStore = ConfigStore(dataDir: dataDir)
        let configuration = HostServerConfiguration(
            rendererDir: rendererDir, dataDir: dataDir, version: "test-version", proxyUserAgent: "test")
        let router = HostServer.makeRouter(configuration: configuration, hub: EventHub(), configStore: configStore)
        return Fixture(dataDir: dataDir, rendererDir: rendererDir, app: Application(router: router), configStore: configStore)
    }

    @Test func configReturnsHostStateWithNullContents() async throws {
        let fixture = try makeFixture()
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/config", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/json")
                let body = String(buffer: response.body)
                #expect(body.contains(#""contents":null"#))
                #expect(body.contains(#""version":"test-version""#))
            }
        }
    }

    @Test func configReturnsSavedContents() async throws {
        let fixture = try makeFixture()
        try await fixture.configStore.save(contents: #"{"configVersion":1}"#, isTemporary: false)
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/config", method: .get) { response in
                #expect(String(buffer: response.body).contains(#"{\"configVersion\":1}"#))
            }
        }
    }

    @Test func servesIndexAndScriptsWithMimeTypes() async throws {
        let fixture = try makeFixture()
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "<html>ok</html>")
            }
            try await client.execute(uri: "/assets/app.js", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType]?.contains("javascript") == true)
            }
        }
    }

    @Test func blocksPathTraversal() async throws {
        let fixture = try makeFixture()
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/../outside.txt", method: .get) { response in
                #expect(String(buffer: response.body) != "secret")
            }
            try await client.execute(uri: "/assets/..%2F..%2Foutside.txt", method: .get) { response in
                #expect(String(buffer: response.body) != "secret")
            }
        }
    }

    @Test func uploadThenDownload() async throws {
        let fixture = try makeFixture()
        try await fixture.app.test(.router) { client in
            let name = try await client.execute(
                uri: "/uploads/picture.png", method: .post, body: ByteBuffer(string: "hello")
            ) { response -> String in
                #expect(response.status == .ok)
                let json = try JSONDecoder().decode([String: String].self, from: Data(String(buffer: response.body).utf8))
                return try #require(json["name"])
            }
            #expect(name == "5d41402abc4b2a76b9719d911017c592.png") // md5("hello")
            try await client.execute(uri: "/uploads/\(name)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "hello")
            }
        }
    }

    @Test func proxyRejectsUnknownHost() async throws {
        let fixture = try makeFixture()
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/proxy/evil.example.com/steal", method: .get) { response in
                #expect(response.status == .forbidden)
            }
        }
    }
}
