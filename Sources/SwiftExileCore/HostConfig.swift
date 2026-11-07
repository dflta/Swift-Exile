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
    /// The library feature (an alpha in the overlay's settings) writes data files (`FileWriter.ts`).
    public var libraryAlpha: Bool
    public var libraryOutputPath: String?
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
        libraryAlpha = false
        libraryOutputPath = nil
        initialDelay = 48
        hideOverlayOnBlur = false
    }

    private enum CodingKeys: String, CodingKey {
        case shortcuts, restoreClipboard, clientLog, gameConfig, stashScroll, overlayKey, logKeys
        case windowTitle, language, readClientLog, libraryAlpha, libraryOutputPath, initialDelay, hideOverlayOnBlur
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
        libraryAlpha = (try? c.decode(Bool.self, forKey: .libraryAlpha)) ?? d.libraryAlpha
        libraryOutputPath = try? c.decodeIfPresent(String.self, forKey: .libraryOutputPath)
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

/// `MAIN->CLIENT::item-text` (`ipc/types.ts:183-192`).
public struct ItemTextPayload: Codable, Sendable, Equatable {
    public struct Point: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
    }
    public var target: String
    public var clipboard: String
    public var position: Point
    public var focusOverlay: Bool

    public init(target: String, clipboard: String, x: Double, y: Double, focusOverlay: Bool) {
        self.target = target
        self.clipboard = clipboard
        self.position = Point(x: x, y: y)
        self.focusOverlay = focusOverlay
    }
}

/// `OVERLAY->MAIN::track-area` (`ipc/types.ts:134-143`).
public struct TrackAreaPayload: Codable, Sendable, Equatable {
    public struct Point: Codable, Sendable, Equatable { public var x: Double; public var y: Double }
    public struct Rect: Codable, Sendable, Equatable { public var x: Double; public var y: Double; public var width: Double; public var height: Double }
    public var holdKey: String
    public var closeThreshold: Double
    public var from: Point
    public var area: Rect
    public var dpr: Double
}

public struct WidgetActionPayload: Codable, Sendable, Equatable {
    public var target: String
    public init(target: String) { self.target = target }
}

public struct VisibilityPayload: Codable, Sendable, Equatable {
    public var isVisible: Bool
    public init(isVisible: Bool) { self.isVisible = isVisible }
}
