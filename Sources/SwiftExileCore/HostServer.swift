import CryptoKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import NIOFoundationCompat

/// Port of `main/src/server.ts` + `file-uploads.ts` + `proxy.ts` routes.
public struct HostServerConfiguration: Sendable {
    public var host: String
    public var port: Int
    /// Folder with the built renderer (`upstream/renderer/dist`). Nil in dev mode (Vite serves it).
    public var rendererDir: URL?
    public var dataDir: URL
    public var version: String
    public var proxyUserAgent: String
    public var trace: @Sendable (String) -> Void

    public init(host: String = "127.0.0.1", port: Int = 0, rendererDir: URL?, dataDir: URL,
                version: String, proxyUserAgent: String, trace: @escaping @Sendable (String) -> Void = { _ in }) {
        self.host = host
        self.port = port
        self.rendererDir = rendererDir
        self.dataDir = dataDir
        self.version = version
        self.proxyUserAgent = proxyUserAgent
        self.trace = trace
    }
}

public enum HostServer {
    /// HTTP routes (everything except the `/events` WebSocket).
    public static func makeRouter(
        configuration: HostServerConfiguration,
        hub: EventHub,
        configStore: ConfigStore
    ) -> Router<BasicRequestContext> {
        let router = Router()
        if let rendererDir = configuration.rendererDir {
            router.add(middleware: FileMiddleware(rendererDir.path, searchForIndexHtml: true))
        }

        router.get("config") { _, _ -> Response in
            let state = HostState(
                contents: await configStore.load(),
                version: configuration.version,
                updater: .initial
            )
            return try jsonResponse(state)
        }

        let uploadsDir = configuration.dataDir.appendingPathComponent("files", isDirectory: true)
        router.get("uploads/{name}") { _, context -> Response in
            let name = try context.parameters.require("name")
            guard isSafeFileName(name),
                  let data = try? Data(contentsOf: uploadsDir.appendingPathComponent(name))
            else { return Response(status: .notFound) }
            return Response(status: .ok, body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
        }
        router.post("uploads/{name}") { request, context -> Response in
            let name = try context.parameters.require("name")
            let body = try await request.body.collect(upTo: 16_000_000) // `file-uploads.ts:23`
            let data = Data(buffer: body)
            let hash = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let ext = (name as NSString).pathExtension
            let fileName = ext.isEmpty ? hash : "\(hash).\(ext)"
            try FileManager.default.createDirectory(at: uploadsDir, withIntermediateDirectories: true)
            try data.write(to: uploadsDir.appendingPathComponent(fileName), options: .atomic)
            return try jsonResponse(["name": fileName])
        }

        let proxy = HttpProxy(
            userAgent: configuration.proxyUserAgent,
            log: { line in await hub.log(line) },
            trace: { line in configuration.trace("[proxy] " + line) }
        )
        for method: HTTPRequest.Method in [.get, .post, .put, .patch, .delete, .head, .options] {
            router.on("proxy/**", method: method) { request, context in
                try await proxy.handle(request, context: context)
            }
        }
        return router
    }

    /// The `/events` WebSocket (`server.ts:81-117`).
    public static func makeWebSocketRouter(hub: EventHub) -> Router<BasicWebSocketRequestContext> {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("events") { inbound, outbound, _ in
            let (id, outgoing) = await hub.connect()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await text in outgoing {
                        try? await outbound.write(.text(text))
                    }
                }
                group.addTask {
                    do {
                        for try await message in inbound.messages(maxSize: 16_000_000) {
                            if case .text(let text) = message {
                                await hub.receive(from: id, text: text)
                            }
                        }
                    } catch {}
                    // Inbound ended: unregister, which also finishes the outgoing stream.
                    await hub.disconnect(id)
                }
            }
        }
        return router
    }

    public static func makeApplication(
        configuration: HostServerConfiguration,
        hub: EventHub,
        configStore: ConfigStore,
        onServerRunning: @escaping @Sendable (Int) async -> Void = { _ in }
    ) -> some ApplicationProtocol {
        Application(
            router: makeRouter(configuration: configuration, hub: hub, configStore: configStore),
            server: .http1WebSocketUpgrade(
                webSocketRouter: makeWebSocketRouter(hub: hub),
                configuration: .init(ws: .init(maxFrameSize: 16_000_000))
            ),
            configuration: .init(address: .hostname(configuration.host, port: configuration.port)),
            onServerRunning: { channel in
                await onServerRunning(channel.localAddress?.port ?? 0)
            }
        )
    }

    /// Starts the server in the background and returns the port it bound to.
    public static func start(
        configuration: HostServerConfiguration,
        hub: EventHub,
        configStore: ConfigStore
    ) async throws -> Int {
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            let app = makeApplication(configuration: configuration, hub: hub, configStore: configStore) { port in
                once.resume(with: .success(port))
            }
            Task.detached {
                do {
                    try await app.runService()
                } catch {
                    once.resume(with: .failure(error))
                }
            }
        }
    }

    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
    }

    static func jsonResponse<T: Encodable>(_ value: T) throws -> Response {
        let data = try JSONEncoder().encode(value)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
    }
}

/// Resumes a continuation at most once (server start can report success and later fail).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Error>?

    func set(_ continuation: CheckedContinuation<Int, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(with result: Result<Int, Error>) {
        let pending: CheckedContinuation<Int, Error>? = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        pending?.resume(with: result)
    }
}
