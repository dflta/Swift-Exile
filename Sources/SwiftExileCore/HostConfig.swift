/// `HostConfig` from `ipc/types.ts:1-16`, sent by the renderer in `CLIENT->MAIN::update-host-config`.
/// Decoded leniently: missing fields fall back to upstream defaults.
public struct HostConfig: Decodable, Sendable, Equatable {
    public var shortcuts: [JSONValue]
    public var restoreClipboard: Bool
    public var clientLog: String?
    public var gameConfig: String?
    public var stashScroll: Bool
    public var overlayKey: String
    public var logKeys: Bool
    public var windowTitle: String
    public var language: String
    public var readClientLog: Bool
    public var initialDelay: Double
    public var hideOverlayOnBlur: Bool

    public static let `default` = HostConfig()

    public init() {
        shortcuts = []
        restoreClipboard = false
        clientLog = nil
        gameConfig = nil
        stashScroll = false
        overlayKey = "Shift + Space"   // renderer default, Config.ts:161
        logKeys = false
        windowTitle = "Path of Exile 2" // renderer default, Config.ts:202
        language = "en"
        readClientLog = false
        initialDelay = 48
        hideOverlayOnBlur = false
    }

    private enum CodingKeys: String, CodingKey {
        case shortcuts, restoreClipboard, clientLog, gameConfig, stashScroll, overlayKey, logKeys
        case windowTitle, language, readClientLog, initialDelay, hideOverlayOnBlur
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HostConfig()
        shortcuts = (try? c.decode([JSONValue].self, forKey: .shortcuts)) ?? d.shortcuts
        restoreClipboard = (try? c.decode(Bool.self, forKey: .restoreClipboard)) ?? d.restoreClipboard
        clientLog = try? c.decodeIfPresent(String.self, forKey: .clientLog)
        gameConfig = try? c.decodeIfPresent(String.self, forKey: .gameConfig)
        stashScroll = (try? c.decode(Bool.self, forKey: .stashScroll)) ?? d.stashScroll
        overlayKey = (try? c.decode(String.self, forKey: .overlayKey)) ?? d.overlayKey
        logKeys = (try? c.decode(Bool.self, forKey: .logKeys)) ?? d.logKeys
        windowTitle = (try? c.decode(String.self, forKey: .windowTitle)) ?? d.windowTitle
        language = (try? c.decode(String.self, forKey: .language)) ?? d.language
        readClientLog = (try? c.decode(Bool.self, forKey: .readClientLog)) ?? d.readClientLog
        initialDelay = (try? c.decode(Double.self, forKey: .initialDelay)) ?? d.initialDelay
        hideOverlayOnBlur = (try? c.decode(Bool.self, forKey: .hideOverlayOnBlur)) ?? d.hideOverlayOnBlur
    }
}

public struct RenderStatePayload: Codable, Sendable {
    public var shouldShow: Bool
}

public struct FocusChangePayload: Codable, Sendable, Equatable {
    public var game: Bool
    public var overlay: Bool
    public var usingHotkey: Bool
    public init(game: Bool, overlay: Bool, usingHotkey: Bool) {
        self.game = game
        self.overlay = overlay
        self.usingHotkey = usingHotkey
    }
}
