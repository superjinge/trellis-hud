import Foundation

/// Manages HUD configuration, socket path derivation, and inbox queue paths.
/// Wire- and path-compatible with `trellis-card` (`~/Library/Application Support/trellis-card/`).
public struct ConfigStore: Sendable {
    public let configDir: URL

    public init(configDir: URL? = nil) {
        if let configDir {
            self.configDir = configDir
        } else {
            self.configDir = Self.defaultConfigDir()
        }
    }

    public static func defaultConfigDir() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["TRELLIS_HUD_CONFIG_DIR"] ?? env["TRELLIS_CARD_CONFIG_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: expandHome(override), isDirectory: true)
        }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("trellis-card", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/trellis-card", isDirectory: true)
    }

    public var configFileURL: URL {
        configDir.appendingPathComponent("config.json", isDirectory: false)
    }

    public var inboxDirURL: URL {
        configDir.appendingPathComponent("inbox", isDirectory: true)
    }

    /// Exact FNV-1a 64-bit socket path matching `trellis-card/src-tauri/src/config.rs::socket_path()`.
    public var socketPath: String {
        Self.socketPath(for: configDir.path)
    }

    public static func socketPath(for configDirPath: String) -> String {
        let normalized = configDirPath.hasSuffix("/") && configDirPath.count > 1
            ? String(configDirPath.dropLast())
            : configDirPath
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "/tmp/trellis-card-%016llx.sock", hash)
    }

    public static func expandHome(_ rawPath: String) -> String {
        if rawPath == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        if rawPath.hasPrefix("~/") {
            let suffix = String(rawPath.dropFirst(2))
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(suffix).path
        }
        return rawPath
    }

    public static func normalizePath(_ rawPath: String) -> String {
        let expanded = expandHome(rawPath)
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let path = url.path
        if path.count > 1 && path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }

    public func load() -> HUDConfig {
        let fm = FileManager.default
        let primary = configFileURL
        let fallback = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/trellis-card/config.json", isDirectory: false)

        let sourceURL: URL
        if fm.fileExists(atPath: primary.path) {
            sourceURL = primary
        } else if fm.fileExists(atPath: fallback.path) {
            sourceURL = fallback
        } else {
            return HUDConfig()
        }

        guard let data = try? Data(contentsOf: sourceURL),
              let decoded = try? JSONDecoder().decode(HUDConfig.self, from: data) else {
            return HUDConfig()
        }
        return decoded
    }

    public func save(_ config: HUDConfig) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let tempURL = configFileURL.appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        if fm.fileExists(atPath: configFileURL.path) {
            _ = try fm.replaceItemAt(configFileURL, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: configFileURL)
        }
    }

    @discardableResult
    public func addRoot(_ path: String) throws -> HUDConfig {
        var config = load()
        let normalized = Self.normalizePath(path)
        config.initialized = true
        if !config.roots.contains(where: { Self.normalizePath($0) == normalized }) {
            config.roots.append(normalized)
        }
        try save(config)
        return config
    }

    @discardableResult
    public func removeRoot(_ path: String) throws -> HUDConfig {
        var config = load()
        let normalized = Self.normalizePath(path)
        config.roots.removeAll { $0 == path || Self.normalizePath($0) == normalized }
        try save(config)
        return config
    }

    @discardableResult
    public func registerDynamicProject(_ path: String) throws -> Bool {
        let normalized = Self.normalizePath(path)
        let tasksDir = URL(fileURLWithPath: normalized).appendingPathComponent(".trellis/tasks", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: tasksDir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        var config = load()
        if config.dynamicProjects.contains(where: { Self.normalizePath($0) == normalized }) {
            return false
        }
        config.dynamicProjects.append(normalized)
        try save(config)
        return true
    }
}
