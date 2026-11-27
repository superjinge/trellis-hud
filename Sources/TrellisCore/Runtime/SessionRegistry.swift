import Foundation

/// Tracks live AI agent sessions and a chronological execution trace across all observed projects.
public struct SessionRegistry: Sendable {
    public var sessions: [String: AgentSessionState]
    public var recentActivities: [ActivityEntry]
    public var activeTimeoutSeconds: TimeInterval
    public var registeredTimeoutSeconds: TimeInterval
    public var maxGlobalActivities: Int
    public var maxSessionActivities: Int

    private static let exactTerminalEvents: Set<String> = [
        "stop",
        "sessionend",
        "session_end",
        "session.end",
        "idle",
        "completed",
        "done",
        "ended",
    ]

    private static let terminalSuffixes: [String] = [
        ".idle", "_idle", "-idle",
        ".completed", "_completed", "-completed",
        ".done", "_done", "-done",
        ".ended", "_ended", "-ended",
    ]

    public init(
        activeTimeoutSeconds: TimeInterval = 300,
        registeredTimeoutSeconds: TimeInterval = 90,
        maxGlobalActivities: Int = 200,
        maxSessionActivities: Int = 50
    ) {
        self.sessions = [:]
        self.recentActivities = []
        self.activeTimeoutSeconds = activeTimeoutSeconds
        self.registeredTimeoutSeconds = registeredTimeoutSeconds
        self.maxGlobalActivities = maxGlobalActivities
        self.maxSessionActivities = maxSessionActivities
    }

    /// Applies an incoming `HookEvent`, updating session state and appending to the execution trace.
    /// Returns `false` if the event is older than the session's last recorded timestamp.
    @discardableResult
    public mutating func apply(_ event: HookEvent) -> Bool {
        let lowerEvent = event.eventName.lowercased()
        let isTerminal = Self.isTerminalEvent(lowerEvent)
        let derivedStatus = Self.deriveStatus(lowerEvent: lowerEvent, isTerminal: isTerminal)
        let eventDate = Date(timeIntervalSince1970: TimeInterval(event.timestamp))
        let normalizedProject = event.project.isEmpty ? "" : ConfigStore.normalizePath(event.project)

        var session = sessions[event.sessionId] ?? AgentSessionState(
            sessionId: event.sessionId,
            agent: event.agent,
            projectPath: normalizedProject,
            taskId: event.taskId,
            status: .idle,
            eventName: event.eventName,
            startedAt: eventDate,
            updatedAt: eventDate
        )

        if eventDate < session.updatedAt {
            return false
        }

        if session.agent == .unknown && event.agent != .unknown {
            session.agent = event.agent
        }
        if !normalizedProject.isEmpty {
            session.projectPath = normalizedProject
        }
        if let taskId = event.taskId, !taskId.isEmpty {
            session.taskId = taskId
        }
        if let action = event.action {
            session.lastAction = action
        }

        session.status = derivedStatus
        session.eventName = event.eventName
        session.updatedAt = eventDate

        // Preserve the last meaningful tool/activity when a terminal event (Stop / session.idle) arrives.
        if !isTerminal {
            if event.toolName != nil { session.toolName = event.toolName }
            if event.toolInput != nil { session.toolInput = event.toolInput }
            if event.activity != nil { session.activity = event.activity }
        }

        let entry = Self.buildActivityEntry(event: event, session: session, status: derivedStatus, timestamp: eventDate)
        session.recentActivities.append(entry)
        if session.recentActivities.count > maxSessionActivities {
            session.recentActivities.removeFirst(session.recentActivities.count - maxSessionActivities)
        }

        recentActivities.append(entry)
        if recentActivities.count > maxGlobalActivities {
            recentActivities.removeFirst(recentActivities.count - maxGlobalActivities)
        }

        sessions[event.sessionId] = session
        return true
    }

    /// Prunes expired sessions and marks quiet active sessions as `.stale`.
    /// Returns `true` if any session was modified or removed.
    @discardableResult
    public mutating func prune(now: Date = Date()) -> Bool {
        var changed = false
        var next: [String: AgentSessionState] = [:]
        next.reserveCapacity(sessions.count)
        for (id, var session) in sessions {
            let age = max(0, now.timeIntervalSince(session.updatedAt))
            switch session.status {
            case .working, .waitingPermission, .waitingQuestion, .failed:
                if age > activeTimeoutSeconds {
                    session.status = .stale
                    changed = true
                }
                next[id] = session
            case .idle, .done, .stale:
                if age <= registeredTimeoutSeconds {
                    next[id] = session
                } else {
                    changed = true
                }
            }
        }
        if changed {
            sessions = next
        }
        return changed
    }

    public func latestSession(forProject projectPath: String, taskId: String, dir: String? = nil) -> AgentSessionState? {
        let targetKey = Self.canonicalPathKey(projectPath)
        return sessions.values
            .filter { session in
                guard Self.canonicalPathKey(session.projectPath) == targetKey else {
                    return false
                }
                guard let sessionTask = session.taskId else { return false }
                return sessionTask == taskId || (dir != nil && sessionTask == dir)
            }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    public func taskId(forSession sessionId: String) -> String? {
        sessions[sessionId]?.taskId
    }

    public func allSessionsSorted() -> [AgentSessionState] {
        sessions.values.sorted { lhs, rhs in
            if lhs.status.priorityRank != rhs.status.priorityRank {
                return lhs.status.priorityRank > rhs.status.priorityRank
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public var attentionCount: Int {
        sessions.values.filter(\.status.isAttentionRequired).count
    }

    public func activities(limit: Int = 50, projectPath: String? = nil) -> [ActivityEntry] {
        let filtered: [ActivityEntry]
        if let projectPath {
            let targetKey = Self.canonicalPathKey(projectPath)
            filtered = recentActivities.filter { Self.canonicalPathKey($0.projectPath) == targetKey }
        } else {
            filtered = recentActivities
        }
        return Array(filtered.suffix(limit).reversed())
    }

    // MARK: - Classification Helpers

    private static func canonicalPathKey(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed.lowercased()
    }

    public static func isTerminalEvent(_ lower: String) -> Bool {
        if exactTerminalEvents.contains(lower) {
            return true
        }
        return terminalSuffixes.contains { lower.hasSuffix($0) }
    }

    private static func deriveStatus(lowerEvent: String, isTerminal: Bool) -> RuntimeStatus {
        if lowerEvent.contains("permission") {
            return .waitingPermission
        }
        if lowerEvent.contains("question") || lowerEvent.contains("askuser") {
            return .waitingQuestion
        }
        if isTerminal {
            return .done
        }
        if lowerEvent == "sessionstart" || lowerEvent == "session_start" {
            return .idle
        }
        if lowerEvent.contains("error") || lowerEvent.contains("fail") {
            return .failed
        }
        return .working
    }

    private static func buildActivityEntry(
        event: HookEvent,
        session: AgentSessionState,
        status: RuntimeStatus,
        timestamp: Date
    ) -> ActivityEntry {
        let targetPath = event.toolInput?.filePath
        let summary: String
        if let desc = event.toolInput?.description, !desc.isEmpty {
            summary = desc
        } else if let cmd = event.toolInput?.command, !cmd.isEmpty {
            summary = truncate(cmd, limit: 120)
        } else if let path = targetPath, !path.isEmpty {
            let tool = event.toolName ?? "File"
            summary = "\(tool): \(URL(fileURLWithPath: path).lastPathComponent)"
        } else if let activity = event.activity, !activity.isEmpty {
            summary = truncate(activity, limit: 120)
        } else if let tool = event.toolName, !tool.isEmpty {
            summary = tool
        } else {
            summary = event.eventName
        }

        let outcome: ActivityOutcome
        switch status {
        case .waitingPermission, .waitingQuestion: outcome = .waiting
        case .failed: outcome = .failed
        case .done: outcome = .succeeded
        case .working: outcome = .running
        case .stale, .idle: outcome = .info
        }

        return ActivityEntry(
            timestamp: timestamp,
            agent: session.agent,
            sessionId: event.sessionId,
            projectPath: session.projectPath,
            taskId: session.taskId,
            toolName: event.toolName,
            summary: summary,
            targetPath: targetPath,
            outcome: outcome
        )
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit - 1)) + "…"
    }
}
