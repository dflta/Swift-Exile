import Foundation

/// Port of the WebSocket routing in `main/src/server.ts` plus `RemoteLogger.ts`.
///
/// Rules preserved from upstream (`server.ts:58-117`):
/// - A new connection becomes the last-active client and immediately receives the log history.
/// - `CLIENT->MAIN::used-recently` makes the sender the last-active client.
/// - When a client disconnects and exactly one remains, that one becomes last-active and the hub
///   emits a synthetic `used-recently {isOverlay: true}`.
/// - `"any"` targets behave like `"last-active"`.
public actor EventHub {
    public enum Target: Sendable { case lastActive, broadcast }
    public typealias Handler = @Sendable (JSONValue?) async -> Void
    public typealias LogSink = @Sendable (String) -> Void

    private var clients: [UUID: AsyncStream<String>.Continuation] = [:]
    private var connectionOrder: [UUID] = []
    private var lastActive: UUID?
    private var handlers: [String: [Handler]] = [:]
    private(set) public var logHistory = ""
    private let logSink: LogSink?
    private let clock: @Sendable () -> String

    public init(
        logSink: LogSink? = nil,
        clock: @escaping @Sendable () -> String = EventHub.localeTime
    ) {
        self.logSink = logSink
        self.clock = clock
    }

    public static let localeTime: @Sendable () -> String = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: Date())
    }

    // MARK: Connections

    /// Registers a client. The returned stream yields every text frame to send to it.
    public func connect() -> (id: UUID, outbound: AsyncStream<String>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<String>.makeStream()
        clients[id] = continuation
        connectionOrder.append(id)
        lastActive = id
        send(to: id, IpcMessageCache.logEntry(logHistory))
        return (id, stream)
    }

    public func receive(from id: UUID, text: String) async {
        guard let message = try? IpcMessage.parse(text) else {
            log("warn [Host] Dropped malformed IPC message")
            return
        }
        if message.name == IpcEventName.usedRecently.rawValue {
            lastActive = id
        }
        await dispatch(message.name, message.payload)
    }

    public func disconnect(_ id: UUID) async {
        clients.removeValue(forKey: id)?.finish()
        connectionOrder.removeAll { $0 == id }
        if clients.count == 1, let remaining = connectionOrder.first {
            lastActive = remaining
            let payload = try? JSONValue(encoding: UsedRecentlyPayload(isOverlay: true))
            await dispatch(IpcEventName.usedRecently.rawValue, payload)
        } else if lastActive == id {
            // Upstream keeps a dangling reference here; fall back to the newest client instead.
            lastActive = connectionOrder.last
        }
    }

    public var clientCount: Int { clients.count }
    public var lastActiveClient: UUID? { lastActive }

    // MARK: Events

    public func on(_ name: IpcEventName, _ handler: @escaping Handler) {
        handlers[name.rawValue, default: []].append(handler)
    }

    public func send(_ target: Target, _ message: IpcMessage) {
        guard let text = try? message.jsonString() else { return }
        switch target {
        case .broadcast:
            for continuation in clients.values { continuation.yield(text) }
        case .lastActive:
            if let id = lastActive { clients[id]?.yield(text) }
        }
    }

    /// Port of `Logger.write`: timestamped line, kept in history and broadcast to every client.
    public func log(_ message: String) {
        let line = "[\(clock())] \(message)\n"
        logHistory += line
        logSink?(line)
        send(.broadcast, IpcMessageCache.logEntry(line))
    }

    private func send(to id: UUID, _ message: IpcMessage) {
        guard let text = try? message.jsonString() else { return }
        clients[id]?.yield(text)
    }

    private func dispatch(_ name: String, _ payload: JSONValue?) async {
        for handler in handlers[name] ?? [] {
            await handler(payload)
        }
    }
}

private enum IpcMessageCache {
    static func logEntry(_ message: String) -> IpcMessage {
        IpcMessage(
            name: IpcEventName.logEntry.rawValue,
            payload: .object(["message": .string(message)])
        )
    }
}
