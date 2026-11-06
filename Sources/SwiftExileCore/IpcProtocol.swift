import Foundation

/// Every event name in the `IpcEvent` union of upstream `ipc/types.ts`.
/// A contract test (planned, §4.2 of the plan) will compare this list against upstream.
public enum IpcEventName: String, CaseIterable, Sendable {
    // Overlay-only events
    case overlayAttached = "MAIN->OVERLAY::overlay-attached"
    case focusChange = "MAIN->OVERLAY::focus-change"
    case visibility = "MAIN->OVERLAY::visibility"
    case focusGame = "OVERLAY->MAIN::focus-game"
    case renderState = "OVERLAY->MAIN::render-state"
    case hideExclusiveWidget = "MAIN->OVERLAY::hide-exclusive-widget"
    case trackArea = "OVERLAY->MAIN::track-area"
    // Events for any client
    case saveConfig = "CLIENT->MAIN::save-config"
    case updaterState = "MAIN->CLIENT::updater-state"
    case gameLog = "MAIN->CLIENT::game-log"
    case usedRecently = "CLIENT->MAIN::used-recently"
    case logEntry = "MAIN->CLIENT::log-entry"
    case updateHostConfig = "CLIENT->MAIN::update-host-config"
    case widgetAction = "MAIN->CLIENT::widget-action"
    case itemText = "MAIN->CLIENT::item-text"
    case ocrText = "MAIN->CLIENT::ocr-text"
    case configChanged = "MAIN->CLIENT::config-changed"
    case userAction = "CLIENT->MAIN::user-action"
    case writeData = "CLIENT->MAIN::write-data"
    case reparseLog = "CLIENT->MAIN::re-parse-log"
}

/// Wire format: `{"name": ..., "payload": ...}`.
/// Payload-less events omit the `payload` key, exactly like `JSON.stringify` does upstream.
public struct IpcMessage: Codable, Sendable, Equatable {
    public var name: String
    public var payload: JSONValue?

    public init(name: String, payload: JSONValue? = nil) {
        self.name = name
        self.payload = payload
    }

    public init(_ name: IpcEventName) {
        self.init(name: name.rawValue)
    }

    public init<P: Encodable>(_ name: IpcEventName, _ payload: P) throws {
        self.init(name: name.rawValue, payload: try JSONValue(encoding: payload))
    }

    public var eventName: IpcEventName? { IpcEventName(rawValue: name) }

    public func jsonString() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    public static func parse(_ text: String) throws -> IpcMessage {
        try JSONDecoder().decode(IpcMessage.self, from: Data(text.utf8))
    }
}

// MARK: - Payloads used so far

public struct SaveConfigPayload: Codable, Sendable {
    public var contents: String
    public var isTemporary: Bool
}

public struct ConfigChangedPayload: Codable, Sendable {
    public var contents: String
    public init(contents: String) { self.contents = contents }
}

public struct LogEntryPayload: Codable, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
}

public struct UsedRecentlyPayload: Codable, Sendable {
    public var isOverlay: Bool
    public init(isOverlay: Bool) { self.isOverlay = isOverlay }
}

public struct UserActionPayload: Codable, Sendable {
    public var action: String
    public var text: String?
}

/// `UpdateInfo` from `ipc/types.ts`. Only the states the host can currently report.
public enum UpdateInfo: Sendable, Equatable {
    case initial
    case updateNotAvailable(checkedAt: Double)
}

extension UpdateInfo: Encodable {
    private enum CodingKeys: String, CodingKey { case state, checkedAt }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .initial:
            try container.encode("initial", forKey: .state)
        case .updateNotAvailable(let checkedAt):
            try container.encode("update-not-available", forKey: .state)
            try container.encode(checkedAt, forKey: .checkedAt)
        }
    }
}

/// Body of `GET /config` (`HostState` in `ipc/types.ts`).
public struct HostState: Encodable, Sendable {
    public var contents: String?
    public var version: String
    public var updater: UpdateInfo

    public init(contents: String?, version: String, updater: UpdateInfo) {
        self.contents = contents
        self.version = version
        self.updater = updater
    }

    private enum CodingKeys: String, CodingKey { case contents, version, updater }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Upstream sends `"contents": null` when there is no config yet; keep the key.
        try container.encode(contents, forKey: .contents)
        try container.encode(version, forKey: .version)
        try container.encode(updater, forKey: .updater)
    }
}
