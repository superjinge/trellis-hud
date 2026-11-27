import Foundation

public struct HookInstallStatus: Sendable, Codable, Equatable, Identifiable {
    public var id: String { agent.rawValue }
    public var agent: AgentKind
    public var installed: Bool
    public var configExists: Bool
    public var configPath: String

    public init(agent: AgentKind, installed: Bool, configExists: Bool, configPath: String) {
        self.agent = agent
        self.installed = installed
        self.configExists = configExists
        self.configPath = configPath
    }
}

/// Installs, uninstalls, and inspects observability hooks/bridges for all 7 supported AI coding agents:
/// Claude Code, Codex, Cursor, Pi, OpenCode, DeepSeek Harness (DSH), and Antigravity.
public struct HookInstaller: Sendable {
    public static let supportedAgents: [AgentKind] = [
        .claude, .codex, .cursor, .pi, .opencode, .dsh, .antigravity,
    ]

    private static let claudeCodexEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "Stop",
    ]

    private static let cursorEvents = [
        "sessionStart",
        "preToolUse",
        "beforeShellExecution",
        "stop",
        "sessionEnd",
    ]

    private static let cursorPreToolMatcher = "Shell|Read|Write|Grep|Delete|Task|Edit|MCP"
    private static let antigravityHookKey = "trellis-hud"

    public let configStore: ConfigStore
    public let hookExecutablePath: String

    public init(configStore: ConfigStore = ConfigStore(), hookExecutablePath: String? = nil) {
        self.configStore = configStore
        self.hookExecutablePath = hookExecutablePath ?? Self.resolveDefaultHookExecutable()
    }

    public static func resolveDefaultHookExecutable() -> String {
        let current = Bundle.main.bundleURL
        let helper = current.appendingPathComponent("Contents/Helpers/trellis-card-hook").path
        if FileManager.default.isExecutableFile(atPath: helper) {
            return helper
        }
        let argv0 = ProcessInfo.processInfo.arguments.first ?? "/usr/local/bin/trellis-card-hook"
        if FileManager.default.isExecutableFile(atPath: argv0) {
            return URL(fileURLWithPath: argv0).standardizedFileURL.path
        }
        return argv0
    }

    public static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func isOwnedCommand(_ command: String) -> Bool {
        let unescaped = command
            .replacingOccurrences(of: "'\\''", with: "'")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        guard let hookRange = unescaped.range(of: " hook ") else { return false }
        let exePath = String(unescaped[..<hookRange.lowerBound])
        let base = URL(fileURLWithPath: exePath).lastPathComponent.lowercased()
        return base == "trellis-card"
            || base == "trellis-card-hook"
            || base == "trellis-hud"
    }

    public func configPath(for agent: AgentKind) -> URL {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch agent {
        case .claude:
            if let p = env["TRELLIS_CARD_CLAUDE_CONFIG"] { return URL(fileURLWithPath: p) }
            return home.appendingPathComponent(".claude/settings.json")
        case .codex:
            if let p = env["TRELLIS_CARD_CODEX_CONFIG"] { return URL(fileURLWithPath: p) }
            return home.appendingPathComponent(".codex/hooks.json")
        case .cursor:
            if let p = env["TRELLIS_CARD_CURSOR_CONFIG"] { return URL(fileURLWithPath: p) }
            return home.appendingPathComponent(".cursor/hooks.json")
        case .pi:
            if let p = env["TRELLIS_CARD_PI_EXTENSIONS_FILE"] { return URL(fileURLWithPath: p) }
            return home.appendingPathComponent(".pi/agent/extensions/trellis-card.ts")
        case .opencode:
            if let p = env["TRELLIS_CARD_OPENCODE_PLUGIN_FILE"] { return URL(fileURLWithPath: p) }
            return home.appendingPathComponent(".config/opencode/plugins/trellis-card.js")
        case .dsh:
            if let p = env["TRELLIS_CARD_DSH_DIR"] { return URL(fileURLWithPath: p, isDirectory: true) }
            return configStore.configDir.appendingPathComponent("agents/dsh-trellis-bridge", isDirectory: true)
        case .antigravity:
            if let p = env["TRELLIS_CARD_ANTIGRAVITY_CONFIG"] { return URL(fileURLWithPath: p) }
            return home.appendingPathComponent(".agents/hooks.json")
        case .unknown:
            return configStore.configDir.appendingPathComponent("hooks.json")
        }
    }

    public func hookCommand(for agent: AgentKind) -> String {
        "\(Self.shellSingleQuote(hookExecutablePath)) hook --agent \(agent.rawValue)"
    }

    public func status(for agent: AgentKind) -> HookInstallStatus {
        let path = configPath(for: agent)
        let fm = FileManager.default
        switch agent {
        case .pi, .opencode:
            let exists = fm.fileExists(atPath: path.path)
            return HookInstallStatus(agent: agent, installed: exists, configExists: exists, configPath: path.path)
        case .dsh:
            let pkgExists = fm.fileExists(atPath: path.appendingPathComponent("package.json").path)
            let installed = pkgExists && isDSHMountedInProfile()
            return HookInstallStatus(agent: agent, installed: installed, configExists: pkgExists, configPath: path.path)
        case .claude, .codex, .cursor, .antigravity:
            let exists = fm.fileExists(atPath: path.path)
            guard exists,
                  let data = try? Data(contentsOf: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) else {
                return HookInstallStatus(agent: agent, installed: false, configExists: exists, configPath: path.path)
            }
            return HookInstallStatus(
                agent: agent,
                installed: Self.containsOwnedCommand(obj),
                configExists: true,
                configPath: path.path
            )
        case .unknown:
            return HookInstallStatus(agent: agent, installed: false, configExists: false, configPath: path.path)
        }
    }

    public func allStatuses() -> [HookInstallStatus] {
        Self.supportedAgents.map { status(for: $0) }
    }

    @discardableResult
    public func install(agent: AgentKind, uninstall: Bool = false) throws -> URL {
        let targetPath = configPath(for: agent)
        switch agent {
        case .pi:
            try writeStandaloneTemplate(relativePath: "pi_bridge.ts", to: targetPath, uninstall: uninstall)
            return targetPath
        case .opencode:
            try writeStandaloneTemplate(relativePath: "opencode_plugin.js", to: targetPath, uninstall: uninstall)
            return targetPath
        case .dsh:
            if uninstall {
                try uninstallDSHBridge(at: targetPath)
            } else {
                try installDSHBridge(at: targetPath)
            }
            return targetPath
        case .claude, .codex, .cursor, .antigravity:
            let command = hookCommand(for: agent)
            let (loaded, existed) = try loadJSONObject(at: targetPath)
            let updated: [String: Any]
            switch agent {
            case .cursor:
                updated = try Self.mergeCursorHooks(root: loaded, command: command, uninstall: uninstall)
            case .antigravity:
                updated = try Self.mergeAntigravityHooks(root: loaded, command: command, uninstall: uninstall)
            default:
                updated = try Self.mergeStandardHooks(root: loaded, command: command, uninstall: uninstall)
            }
            if !uninstall || existed {
                try writeJSONAtomic(updated, to: targetPath)
            }
            if agent == .codex && !uninstall {
                try enableCodexHooksFeature()
            }
            return targetPath
        case .unknown:
            throw NSError(domain: "HookInstaller", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported agent kind: unknown",
            ])
        }
    }

    // MARK: - JSON Merge Logic (Pure & Testable)

    public static func mergeStandardHooks(
        root: [String: Any],
        command: String,
        uninstall: Bool
    ) throws -> [String: Any] {
        var result = root
        var hooks = (result["hooks"] as? [String: Any]) ?? [:]
        if uninstall {
            for (key, value) in hooks {
                let cleaned = removeOwnedCommands(from: value)
                if let arr = cleaned as? [Any], arr.isEmpty {
                    hooks.removeValue(forKey: key)
                } else {
                    hooks[key] = cleaned
                }
            }
            result["hooks"] = hooks
            return result
        }

        for event in claudeCodexEvents {
            var entries = (hooks[event] as? [Any]) ?? []
            var attached = false
            for idx in entries.indices {
                if var entryObj = entries[idx] as? [String: Any],
                   var nested = entryObj["hooks"] as? [Any] {
                    let alreadyPresent = nested.contains { item in
                        guard let dict = item as? [String: Any],
                              let cmd = dict["command"] as? String else { return false }
                        return isOwnedCommand(cmd)
                    }
                    if !alreadyPresent {
                        nested.append(["type": "command", "command": command])
                        entryObj["hooks"] = nested
                        entries[idx] = entryObj
                    }
                    attached = true
                    break
                }
            }
            if !attached {
                let alreadyDirect = entries.contains { item in
                    guard let dict = item as? [String: Any],
                          let cmd = dict["command"] as? String else { return false }
                    return isOwnedCommand(cmd)
                }
                if !alreadyDirect {
                    entries.append([
                        "matcher": "*",
                        "hooks": [["type": "command", "command": command]],
                    ])
                }
            }
            hooks[event] = entries
        }
        result["hooks"] = hooks
        return result
    }

    public static func mergeCursorHooks(
        root: [String: Any],
        command: String,
        uninstall: Bool
    ) throws -> [String: Any] {
        var result = root
        if result["version"] == nil {
            result["version"] = 1
        }
        var hooks = (result["hooks"] as? [String: Any]) ?? [:]
        if uninstall {
            for (key, value) in hooks {
                let cleaned = removeOwnedCommands(from: value)
                if let arr = cleaned as? [Any], arr.isEmpty {
                    hooks.removeValue(forKey: key)
                } else {
                    hooks[key] = cleaned
                }
            }
            result["hooks"] = hooks
            return result
        }

        for event in cursorEvents {
            var entries = (hooks[event] as? [Any]) ?? []
            let exists = entries.contains { item in
                guard let dict = item as? [String: Any],
                      let cmd = dict["command"] as? String else { return false }
                return isOwnedCommand(cmd)
            }
            if !exists {
                var hookEntry: [String: Any] = ["command": command, "timeout": 30]
                if event == "preToolUse" {
                    hookEntry["matcher"] = cursorPreToolMatcher
                }
                entries.append(hookEntry)
            }
            hooks[event] = entries
        }
        result["hooks"] = hooks
        return result
    }

    /// Antigravity `.agents/hooks.json` uses top-level named groups:
    /// `{ "trellis-hud": { "enabled": true, "SessionStart": [...], "PreInvocation": [...], "PreToolUse": [...], "PostToolUse": [...], "Stop": [...] } }`.
    public static func mergeAntigravityHooks(
        root: [String: Any],
        command: String,
        uninstall: Bool
    ) throws -> [String: Any] {
        var result = root
        if uninstall {
            result.removeValue(forKey: antigravityHookKey)
            for (key, value) in result {
                if containsOwnedCommand(value) {
                    result[key] = removeOwnedCommands(from: value)
                }
            }
            return result
        }

        let cmdEntry: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": 10,
        ]
        result[antigravityHookKey] = [
            "enabled": true,
            "SessionStart": [cmdEntry],
            "PreInvocation": [cmdEntry],
            "PreToolUse": [
                [
                    "matcher": "*",
                    "hooks": [cmdEntry],
                ],
            ],
            "PostToolUse": [
                [
                    "matcher": "*",
                    "hooks": [cmdEntry],
                ],
            ],
            "Stop": [cmdEntry],
        ]
        return result
    }

    public static func containsOwnedCommand(_ value: Any) -> Bool {
        if let dict = value as? [String: Any] {
            if let cmd = dict["command"] as? String, isOwnedCommand(cmd) {
                return true
            }
            return dict.values.contains { containsOwnedCommand($0) }
        }
        if let arr = value as? [Any] {
            return arr.contains { containsOwnedCommand($0) }
        }
        return false
    }

    public static func removeOwnedCommands(from value: Any) -> Any {
        if var dict = value as? [String: Any] {
            if let hooks = dict["hooks"] {
                dict["hooks"] = removeOwnedCommands(from: hooks)
            }
            return dict
        }
        if let arr = value as? [Any] {
            var filtered: [Any] = []
            for item in arr {
                if let dict = item as? [String: Any],
                   let cmd = dict["command"] as? String,
                   isOwnedCommand(cmd) {
                    continue
                }
                let cleaned = removeOwnedCommands(from: item)
                // Strip empty wrapper objects like `{"matcher": "*", "hooks": []}` left behind after uninstall.
                if let cleanedDict = cleaned as? [String: Any],
                   let nestedHooks = cleanedDict["hooks"] as? [Any],
                   nestedHooks.isEmpty,
                   containsOwnedCommand(item) {
                    continue
                }
                filtered.append(cleaned)
            }
            return filtered
        }
        return value
    }

    // MARK: - Codex TOML, Standalone Templates & DSH

    private func enableCodexHooksFeature() throws {
        let env = ProcessInfo.processInfo.environment
        let tomlURL: URL
        if let p = env["TRELLIS_CARD_CODEX_CONFIG_TOML"] {
            tomlURL = URL(fileURLWithPath: p)
        } else {
            tomlURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        }
        let existing: String
        if FileManager.default.fileExists(atPath: tomlURL.path) {
            existing = try String(contentsOf: tomlURL, encoding: .utf8)
        } else {
            existing = ""
        }
        let updated = Self.upsertCodexHooksTOML(existing)
        try writeDataAtomic(Data(updated.utf8), to: tomlURL)
    }

    public static func upsertCodexHooksTOML(_ content: String) -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inFeatures = false
        var featuresHeaderIdx: Int?
        var hooksLineIdx: Int?

        for (idx, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inFeatures = (trimmed == "[features]")
                if inFeatures { featuresHeaderIdx = idx }
                continue
            }
            if inFeatures {
                let lhs = trimmed.split(separator: "=", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespaces)
                if lhs == "hooks" {
                    hooksLineIdx = idx
                    break
                }
            }
        }

        if let idx = hooksLineIdx {
            lines[idx] = "hooks = true"
        } else if let headerIdx = featuresHeaderIdx {
            lines.insert("hooks = true", at: headerIdx + 1)
        } else {
            if !content.isEmpty && !content.hasSuffix("\n") {
                lines.append("")
            }
            lines.append("[features]")
            lines.append("hooks = true")
        }
        return lines.joined(separator: "\n") + (lines.last?.isEmpty == true ? "" : "\n")
    }

    private func writeStandaloneTemplate(relativePath: String, to targetPath: URL, uninstall: Bool) throws {
        let fm = FileManager.default
        if uninstall {
            if fm.fileExists(atPath: targetPath.path) {
                try fm.removeItem(at: targetPath)
            }
            return
        }
        let content = try loadBundledTemplate(relativePath: relativePath)
        try writeDataAtomic(content, to: targetPath)
    }

    /// Resolves template assets across app bundles, helper-relative paths, and repo dev trees.
    /// `Resources/templates` is the single source of truth.
    public static func locateTemplatesDirectory() -> URL? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidates: [URL] = []

        if let override = env["TRELLIS_HUD_TEMPLATES_DIR"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: ConfigStore.expandHome(override), isDirectory: true))
        }
        if let resURL = Bundle.main.resourceURL {
            candidates.append(resURL.appendingPathComponent("templates", isDirectory: true))
            candidates.append(resURL.appendingPathComponent("Templates", isDirectory: true))
        }
        if let exeArg = ProcessInfo.processInfo.arguments.first {
            let exeURL = URL(fileURLWithPath: exeArg).standardizedFileURL.resolvingSymlinksInPath()
            let exeDir = exeURL.deletingLastPathComponent()
            // Contents/MacOS/TrellisHUD or Contents/Helpers/trellis-card-hook -> Contents/Resources/templates
            candidates.append(exeDir.deletingLastPathComponent().appendingPathComponent("Resources/templates", isDirectory: true))
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("Resources/templates", isDirectory: true))

        for dir in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                return dir
            }
        }
        return nil
    }

    private func loadBundledTemplate(relativePath: String) throws -> Data {
        if let root = Self.locateTemplatesDirectory() {
            let fileURL = root.appendingPathComponent(relativePath, isDirectory: false)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return try Data(contentsOf: fileURL)
            }
        }
        throw NSError(domain: "HookInstaller", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Bundled template not found: \(relativePath)",
        ])
    }

    private func installDSHBridge(at dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("src", isDirectory: true), withIntermediateDirectories: true)
        for rel in ["package.json", "cordis.patch.yml", "src/index.js", "src/lib.js"] {
            let data = try loadBundledTemplate(relativePath: "dsh/\(rel)")
            try writeDataAtomic(data, to: dir.appendingPathComponent(rel))
        }
        _ = try runDSHPlugin(args: ["add", "link:\(dir.path)"])
    }

    private func uninstallDSHBridge(at dir: URL) throws {
        _ = try? runDSHPlugin(args: ["remove", "dsh-trellis-bridge"])
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    private func isDSHMountedInProfile() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let manifestURL: URL
        if let override = env["TRELLIS_CARD_DSH_PROFILE_MANIFEST"] {
            manifestURL = URL(fileURLWithPath: override)
        } else {
            manifestURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".dsh/profiles/web/package.json")
        }
        guard let data = try? Data(contentsOf: manifestURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dsh = obj["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String] else {
            return false
        }
        return bundles.contains("dsh-trellis-bridge")
    }

    private func runDSHPlugin(args: [String]) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/dsh",
            "/usr/local/bin/dsh",
            "/usr/bin/dsh",
            "\(home)/.local/bin/dsh",
        ]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "HookInstaller", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "dsh CLI not found. Install DeepSeek Harness first.",
            ])
        }
        let result = SubprocessRunner.run(
            executable: bin,
            arguments: ["plugin", "--profile", "web"] + args,
            environment: TaskActionRunner.augmentedEnvironment(),
            timeoutSeconds: 15.0
        )
        guard result.succeeded else {
            let reason = result.timedOut ? "timed out" : "\(result.stderr)\(result.stdout)"
            throw NSError(domain: "HookInstaller", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: "dsh plugin failed: \(reason)",
            ])
        }
        return result.stdout
    }

    private func loadJSONObject(at url: URL) throws -> ([String: Any], Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ([:], false)
        }
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "HookInstaller", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Hook config root must be a JSON object: \(url.path)",
            ])
        }
        return (obj, true)
    }

    private func writeJSONAtomic(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try writeDataAtomic(data, to: url)
    }

    private func writeDataAtomic(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
