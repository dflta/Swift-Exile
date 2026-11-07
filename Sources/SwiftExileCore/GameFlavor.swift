import Darwin
import Foundation

/// Arguments and environment of another process of the same user (`sysctl KERN_PROCARGS2`).
public struct ProcessArguments: Equatable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]

    /// Reads a live process. Works for processes of the same user without extra permissions.
    public static func read(pid: pid_t) -> ProcessArguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(Array(buffer.prefix(size)))
    }

    /// Layout: `int32 argc`, executable path, NUL padding, `argc` NUL-terminated arguments
    /// (which may be empty strings), then `KEY=VALUE` environment strings.
    public static func parse(_ bytes: [UInt8]) -> ProcessArguments? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = 4

        func readString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count && bytes[index] != 0 { index += 1 }
            let value = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1 // skip NUL
            return value
        }

        guard let executablePath = readString() else { return nil }
        while index < bytes.count && bytes[index] == 0 { index += 1 } // padding after the exec path

        var arguments: [String] = []
        for _ in 0..<max(0, argc) {
            guard let argument = readString() else { break }
            arguments.append(argument)
        }

        // Wine rewrites argv in place, leaving runs of empty strings before the environment,
        // so skip empties instead of treating them as the end.
        var environment: [String: String] = [:]
        while let entry = readString() {
            if let separator = entry.firstIndex(of: "="), separator != entry.startIndex {
                environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
            }
        }
        return ProcessArguments(executablePath: executablePath, arguments: arguments, environment: environment)
    }
}

/// How the game is running (plan §0.2). Chosen once per attach.
public enum GameFlavor: Equatable, Sendable {
    /// Windows client under a Wine layer (NotProton, CrossOver, Whisky…).
    case wine(prefix: String?, installDir: String?)
    /// Native macOS client.
    case native(bundleID: String)
    case unknown

    public static func detect(bundleID: String?, processArguments: ProcessArguments?) -> GameFlavor {
        let environment = processArguments?.environment ?? [:]
        let isWine = environment["WINEPREFIX"] != nil
            || environment["WINELOADER"] != nil
            || environment["WINEPRELOADERAPPNAME"] != nil
            || (processArguments?.arguments.first?.lowercased().hasSuffix(".exe") ?? false)
        if isWine {
            let installDir = environment["STEAM_COMPAT_INSTALL_PATH"] ?? environment["PWD"]
            return .wine(prefix: environment["WINEPREFIX"], installDir: installDir)
        }
        if let bundleID, !bundleID.isEmpty {
            return .native(bundleID: bundleID)
        }
        return .unknown
    }

    /// Game settings file implied by this flavor, if it can be derived (plan §2.7, step 1).
    public var derivedConfigPath: String? {
        guard case .wine(let prefix?, _) = self else { return nil }
        let users = URL(fileURLWithPath: prefix).appendingPathComponent("drive_c/users")
        let candidates = (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []
        for user in candidates.sorted() where user != "Public" {
            let path = users.appendingPathComponent(user)
                .appendingPathComponent("Documents/My Games/Path of Exile 2/poe2_production_Config.ini").path
            if FileManager.default.isReadableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Game log implied by this flavor, if it can be derived.
    public var derivedClientLogPath: String? {
        guard case .wine(_, let installDir?) = self else { return nil }
        return URL(fileURLWithPath: installDir).appendingPathComponent("logs/Client.txt").path
    }

    public var displayName: String {
        switch self {
        case .wine: return "Windows client (Wine)"
        case .native: return "Native macOS client"
        case .unknown: return "Unknown"
        }
    }
}
