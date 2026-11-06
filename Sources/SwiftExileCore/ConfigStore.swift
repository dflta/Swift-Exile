import Foundation

public enum HostPaths {
    /// Same folder the Electron app uses (`app.getPath("userData")/apt-data`), so users keep their settings.
    /// Override with `SWIFTEXILE_DATA_DIR` for development, so a test run never touches real settings.
    public static func dataDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["SWIFTEXILE_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("exiled-exchange-2", isDirectory: true)
            .appendingPathComponent("apt-data", isDirectory: true)
    }
}

/// Port of `main/src/host-files/ConfigStore.ts`. The config is an opaque string: the host never parses it.
public actor ConfigStore {
    private var configURL: URL
    private var isTmpFile = false
    private let readOnly: Bool

    /// - Parameter readOnly: mirrors upstream's "no saves in dev mode" (`ConfigStore.ts:33`).
    public init(dataDir: URL, readOnly: Bool = false) {
        self.configURL = dataDir.appendingPathComponent("config.json")
        self.readOnly = readOnly
    }

    public var currentPath: URL { configURL }

    public func load() -> String? {
        try? String(contentsOf: configURL, encoding: .utf8)
    }

    public func save(contents: String, isTemporary: Bool) throws {
        if readOnly { return }
        // Once a temporary save happens, every later save goes to the .tmp file (`ConfigStore.ts:35-38`).
        if isTemporary && !isTmpFile {
            configURL = configURL.deletingLastPathComponent()
                .appendingPathComponent(configURL.lastPathComponent + ".tmp")
            isTmpFile = true
        }
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic write: an improvement over upstream's plain writeFile.
        try Data(contents.utf8).write(to: configURL, options: .atomic)
    }
}
