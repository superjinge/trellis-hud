import Foundation

public struct HookOverrides: Sendable, Equatable {
    public var agent: String?
    public var event: String?
    public var session: String?
    public var project: String?
    public var task: String?

    public init(
        agent: String? = nil,
        event: String? = nil,
        session: String? = nil,
        project: String? = nil,
        task: String? = nil
    ) {
        self.agent = agent
        self.event = event
        self.session = session
        self.project = project
        self.task = task
    }
}

/// Parses stdin JSON payloads from Claude Code, Codex, Cursor, Pi, OpenCode, DSH, and Antigravity hooks.
public enum HookEventParser {
    private static let nativeToolToAction: [String: TrellisAction] = [
        "trellis-create": .create,
        "trellis-brainstorm": .brainstorm,
        "trellis-research": .research,
        "trellis-prd": .prd,
        "trellis-context": .context,
        "trellis-implement": .implement,
        "trellis-check": .check,
        "trellis-rollback": .rollback,
        "trellis-break-loop": .breakLoop,
        "trellis-update-spec": .updateSpec,
        "trellis-archive": .archive,
    ]

    private static let skillToAction: [String: TrellisAction] = [
        "trellis-brainstorm": .brainstorm,
        "trellis-research": .research,
        "trellis-implement": .implement,
        "trellis-check": .check,
        "trellis-break-loop": .breakLoop,
        "trellis-update-spec": .updateSpec,
    ]

    public static func classifyTool(toolName: String, command: String, skill: String) -> TrellisAction? {
        let trimmedTool = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let action = nativeToolToAction[trimmedTool] {
            return action
        }
        let trimmedSkill = skill.trimmingCharacters(in: .whitespacesAndNewlines)
        if let action = skillToAction[trimmedSkill] {
            return action
        }

        let segments = command.split { ["&", "|", ";", "\n", "\r"].contains($0) }
        for segment in segments {
            let tokens = segment
                .split(whereSeparator: \.isWhitespace)
                .map { stripQuotes(String($0)).replacingOccurrences(of: "\\", with: "/") }

            if tokens.contains(where: { $0 == "get_context.py" || $0.hasSuffix("/get_context.py") }) {
                return .context
            }
            for (idx, token) in tokens.enumerated() {
                if (token == "task.py" || token.hasSuffix("/task.py")), idx + 1 < tokens.count {
                    if let action = actionForTaskSubcommand(tokens[idx + 1]) {
                        return action
                    }
                }
            }
        }
        return nil
    }

    private static func actionForTaskSubcommand(_ subcommand: String) -> TrellisAction? {
        switch subcommand {
        case "create": return .create
        case "start", "activate": return .activate
        case "add-context", "context": return .context
        case "archive", "finish-work": return .archive
        case "rollback": return .rollback
        default: return nil
        }
    }

    public static func extractTaskDir(from text: String) -> String? {
        let trimChars = CharacterSet(charactersIn: "'\"()[]{}<>,;")
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let token = String(raw)
                .trimmingCharacters(in: trimChars)
                .replacingOccurrences(of: "\\", with: "/")
            let parts = token.split(separator: "/").map(String.init)
            guard parts.count >= 3 else { continue }
            for i in 0...(parts.count - 3) {
                if parts[i] == ".trellis" && parts[i + 1] == "tasks" && !parts[i + 2].isEmpty {
                    return parts[i + 2]
                }
            }
        }
        return nil
    }

    public static func parsePayload(
        _ input: String,
        overrides: HookOverrides = HookOverrides(),
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> HookEvent {
        let normalizedInput = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : input
        guard let data = normalizedInput.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "HookEventParser", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Hook payload must be a JSON object",
            ])
        }

        let command = commandFromPayload(json)
        let inputText = toolInputText(json)
        let toolInput = toolActivityInput(json)
        let toolName = stringValue(json, keys: ["tool_name", "toolName", "tool"])
        let skill = stringValue(json, keys: ["skill", "skill_name", "skillName"]) ?? ""

        let rawProject = overrides.project
            ?? nonEmptyString(json, keys: ["cwd", "project", "projectPath", "workspace"])
            ?? workspaceRoot(json)
            ?? FileManager.default.currentDirectoryPath
        let project = projectRootForPath(rawProject)

        let sessionId = overrides.session
            ?? nonEmptyString(json, keys: ["session_id", "sessionId", "session", "conversation_id", "conversationId"])
            ?? "unknown-session"

        let explicitTask = overrides.task
            ?? nonEmptyString(json, keys: ["task_id", "taskId", "current_task", "currentTask"]).map {
                extractTaskDir(from: $0) ?? $0
            }

        let taskId = explicitTask
            ?? taskDirFromPayload(project: project, input: command)
            ?? taskDirFromPayload(project: project, input: inputText)
            ?? extractTaskArg(command: command, toolName: toolName)
            ?? runtimeTaskForSession(project: project, sessionId: sessionId)
            ?? currentTaskFallback(project: project)
            ?? runtimeTaskForProject(project: project)
            ?? taskDirFromPayload(project: project, input: normalizedInput)

        let timestamp = int64Value(json, keys: ["timestamp"]) ?? now

        let eventName = overrides.event
            ?? nonEmptyString(json, keys: ["hook_event_name", "hookEventName", "event_name", "event"])
            ?? "SessionStart"

        let agentKind = overrides.agent
            ?? nonEmptyString(json, keys: ["agent", "agent_kind", "agentKind"])
            ?? "unknown"

        let activity: String?
        if !command.isEmpty {
            activity = command
        } else if !inputText.isEmpty {
            activity = inputText
        } else {
            activity = nonEmptyString(json, keys: ["prompt", "message", "input"]) ?? toolName
        }

        let action = classifyTool(toolName: toolName ?? "", command: command, skill: skill)

        return HookEvent(
            sessionId: sessionId,
            agentKind: agentKind,
            project: project,
            taskId: taskId,
            eventName: eventName,
            toolName: toolName,
            toolInput: toolInput,
            activity: activity,
            action: action,
            timestamp: timestamp
        )
    }

    // MARK: - Helpers

    private static func stripQuotes(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    private static func stringValue(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                return value
            }
        }
        return nil
    }

    private static func nonEmptyString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func int64Value(_ dict: [String: Any], keys: [String]) -> Int64? {
        for key in keys {
            if let value = dict[key] as? Int64 {
                return value
            }
            if let value = dict[key] as? Int {
                return Int64(value)
            }
            if let value = dict[key] as? Double {
                return Int64(value)
            }
        }
        return nil
    }

    private static func workspaceRoot(_ dict: [String: Any]) -> String? {
        guard let roots = dict["workspace_roots"] as? [Any] else { return nil }
        for item in roots {
            if let s = item as? String, !s.isEmpty {
                return s
            }
        }
        return nil
    }

    private static func toolInputObject(_ dict: [String: Any]) -> Any? {
        dict["tool_input"] ?? dict["toolInput"]
    }

    private static func toolActivityInput(_ dict: [String: Any]) -> ToolActivityInput? {
        guard let input = toolInputObject(dict) as? [String: Any] else { return nil }
        let value = ToolActivityInput(
            filePath: nonEmptyString(input, keys: ["file_path", "filePath", "path", "Path"]),
            command: nonEmptyString(input, keys: ["command", "cmd", "script", "CommandLine"]),
            description: nonEmptyString(input, keys: ["description", "toolSummary"]),
            pattern: nonEmptyString(input, keys: ["pattern"]),
            query: nonEmptyString(input, keys: ["query"]),
            url: nonEmptyString(input, keys: ["url"]),
            prompt: nonEmptyString(input, keys: ["prompt"]),
            subagentType: nonEmptyString(input, keys: ["subagent_type", "subagentType"])
        )
        return value.isEmpty ? nil : value
    }

    private static func commandFromPayload(_ dict: [String: Any]) -> String {
        if let input = toolInputObject(dict) {
            if let s = input as? String {
                return s
            }
            if let obj = input as? [String: Any],
               let cmd = nonEmptyString(obj, keys: ["command", "cmd", "script", "CommandLine"]) {
                return cmd
            }
        }
        return nonEmptyString(dict, keys: ["command", "cmd"]) ?? ""
    }

    private static func toolInputText(_ dict: [String: Any]) -> String {
        guard let input = toolInputObject(dict) else { return "" }
        if let s = input as? String {
            return s
        }
        if let obj = input as? [String: Any] {
            if let text = nonEmptyString(obj, keys: [
                "command", "cmd", "script", "CommandLine",
                "file_path", "filePath", "path", "Path",
                "pattern", "query", "url", "prompt", "description", "toolSummary",
            ]) {
                return text
            }
            if let data = try? JSONSerialization.data(withJSONObject: obj),
               let encoded = String(data: data, encoding: .utf8) {
                return encoded
            }
        }
        return ""
    }

    private static func projectRootForPath(_ path: String) -> String {
        let fm = FileManager.default
        var current = URL(fileURLWithPath: ConfigStore.expandHome(path))
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: current.path, isDirectory: &isDir), !isDir.boolValue {
            current.deleteLastPathComponent()
        }
        while true {
            let tasksDir = current.appendingPathComponent(".trellis/tasks", isDirectory: true)
            var tasksIsDir: ObjCBool = false
            if fm.fileExists(atPath: tasksDir.path, isDirectory: &tasksIsDir), tasksIsDir.boolValue {
                return ConfigStore.normalizePath(current.path)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return path
            }
            current = parent
        }
    }

    private static func looksLikeTaskId(_ value: String) -> Bool {
        let parts = value.split(separator: "-", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let prefix = parts[0]
        return prefix.count == 2 && prefix.allSatisfy(\.isNumber) && !parts[1].isEmpty
    }

    private static func extractTaskArg(command: String, toolName: String?) -> String? {
        let trimChars = CharacterSet(charactersIn: "'\"()[]{}<>,;")
        let tokens = command.split(whereSeparator: \.isWhitespace).map {
            String($0).trimmingCharacters(in: trimChars).replacingOccurrences(of: "\\", with: "/")
        }
        let trellisTool = toolName.flatMap { $0.hasPrefix("trellis-") ? $0 : nil }
        for (idx, token) in tokens.enumerated() {
            let isTrellisTool = trellisTool.map { token == $0 } ?? false
            let isTaskScript = token == "task.py" || token.hasSuffix("/task.py")
            if !isTrellisTool && !isTaskScript { continue }
            let targetIndex = idx + (isTaskScript ? 2 : 1)
            if targetIndex < tokens.count && looksLikeTaskId(tokens[targetIndex]) {
                return tokens[targetIndex]
            }
        }
        return nil
    }

    private static func taskDirFromPayload(project: String, input: String) -> String? {
        guard !project.isEmpty, !input.isEmpty else { return nil }
        let fm = FileManager.default
        let trimChars = CharacterSet(charactersIn: "'\"()[]{}<>,;")
        let normalizedProject = ConfigStore.normalizePath(project)

        for raw in input.split(whereSeparator: \.isWhitespace) {
            let token = String(raw).trimmingCharacters(in: trimChars).replacingOccurrences(of: "\\", with: "/")
            guard let task = extractTaskDir(from: token) else { continue }
            guard tokenBelongsToProject(normalizedProject: normalizedProject, token: token) else { continue }
            let taskPath = URL(fileURLWithPath: project)
                .appendingPathComponent(".trellis/tasks/\(task)", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: taskPath.path, isDirectory: &isDir), isDir.boolValue {
                return task
            }
        }
        return nil
    }

    private static func tokenBelongsToProject(normalizedProject: String, token: String) -> Bool {
        guard let range = token.range(of: ".trellis/tasks/") else { return false }
        let prefix = String(token[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if prefix.isEmpty || prefix == "." {
            return true
        }
        let rawPrefix = String(token[..<range.lowerBound])
        guard rawPrefix.hasPrefix("/") else { return false }
        return ConfigStore.normalizePath(rawPrefix).lowercased() == normalizedProject.lowercased()
    }

    private static func runtimeTaskForSession(project: String, sessionId: String) -> String? {
        guard !project.isEmpty, !sessionId.isEmpty, sessionId != "unknown-session" else { return nil }
        let sessionsDir = URL(fileURLWithPath: project).appendingPathComponent(".trellis/.runtime/sessions", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        for url in entries where url.pathExtension == "json" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard url.lastPathComponent == sessionId || stem.hasSuffix(sessionId) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let currentTask = nonEmptyString(obj, keys: ["current_task", "currentTask"]) else {
                continue
            }
            return extractTaskDir(from: currentTask)
        }
        return nil
    }

    private static func runtimeTaskForProject(project: String) -> String? {
        guard !project.isEmpty else { return nil }
        let fm = FileManager.default
        let sessionsDir = URL(fileURLWithPath: project).appendingPathComponent(".trellis/.runtime/sessions", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        var candidates: [(String, String)] = []
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let currentTask = nonEmptyString(obj, keys: ["current_task", "currentTask"]),
                  let task = extractTaskDir(from: currentTask) else {
                continue
            }
            let taskPath = URL(fileURLWithPath: project).appendingPathComponent(".trellis/tasks/\(task)", isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: taskPath.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let lastSeen = nonEmptyString(obj, keys: ["last_seen_at", "lastSeenAt"]) ?? ""
            candidates.append((lastSeen, task))
        }
        return candidates.max(by: { $0.0 < $1.0 })?.1
    }

    private static func currentTaskFallback(project: String) -> String? {
        guard !project.isEmpty else { return nil }
        let pointer = URL(fileURLWithPath: project).appendingPathComponent(".trellis/.current-task")
        guard let raw = try? String(contentsOf: pointer, encoding: .utf8) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let task = extractTaskDir(from: text) ?? (looksLikeTaskId(text) ? text : nil)
        guard let task else { return nil }
        let taskPath = URL(fileURLWithPath: project).appendingPathComponent(".trellis/tasks/\(task)", isDirectory: true)
        var isDir: ObjCBool = false
        return (FileManager.default.fileExists(atPath: taskPath.path, isDirectory: &isDir) && isDir.boolValue) ? task : nil
    }
}
