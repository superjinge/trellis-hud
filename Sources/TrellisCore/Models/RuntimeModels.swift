import Foundation

// MARK: - Agent Kind & Runtime Status

public enum AgentKind: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case claude
    case codex
    case cursor
    case pi
    case opencode
    case dsh
    case antigravity
    case unknown

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .pi: return "Pi"
        case .opencode: return "OpenCode"
        case .dsh: return "DeepSeek Harness"
        case .antigravity: return "Antigravity"
        case .unknown: return "Agent"
        }
    }

    public static func from(raw: String) -> AgentKind {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "claude", "claude-code", "claudecode":
            return .claude
        case "codex":
            return .codex
        case "cursor":
            return .cursor
        case "pi":
            return .pi
        case "opencode":
            return .opencode
        case "dsh", "deepseek", "deepseek-harness":
            return .dsh
        case "antigravity", "agy":
            return .antigravity
        default:
            return .unknown
        }
    }
}

public enum RuntimeStatus: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case working
    case waitingPermission = "waiting_permission"
    case waitingQuestion = "waiting_question"
    case done
    case failed
    case stale
    case idle

    public var isAttentionRequired: Bool {
        switch self {
        case .waitingPermission, .waitingQuestion, .failed:
            return true
        case .working, .done, .stale, .idle:
            return false
        }
    }

    /// Higher priority wins when selecting the global HUD status/focus.
    public var priorityRank: Int {
        switch self {
        case .waitingPermission: return 100
        case .waitingQuestion: return 95
        case .failed: return 85
        case .working: return 70
        case .done: return 40
        case .stale: return 20
        case .idle: return 10
        }
    }

    public var label: String {
        switch self {
        case .working: return "Working"
        case .waitingPermission: return "Needs Approval"
        case .waitingQuestion: return "Needs Input"
        case .done: return "Turn Done"
        case .failed: return "Failed"
        case .stale: return "Stale"
        case .idle: return "Idle"
        }
    }
}

public enum TrellisAction: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case create
    case brainstorm
    case research
    case prd
    case context
    case activate
    case implement
    case check
    case rollback
    case breakLoop = "break_loop"
    case updateSpec = "update_spec"
    case archive
}

// MARK: - Tool Input & Wire-Compatible Hook Event

/// Matches `trellis-card/src-tauri/src/runtime.rs::ToolActivityInput` (camelCase JSON).
public struct ToolActivityInput: Sendable, Codable, Equatable, Hashable {
    public var filePath: String?
    public var command: String?
    public var description: String?
    public var pattern: String?
    public var query: String?
    public var url: String?
    public var prompt: String?
    public var subagentType: String?

    public var isEmpty: Bool {
        filePath == nil && command == nil && description == nil && pattern == nil
            && query == nil && url == nil && prompt == nil && subagentType == nil
    }

    public init(
        filePath: String? = nil,
        command: String? = nil,
        description: String? = nil,
        pattern: String? = nil,
        query: String? = nil,
        url: String? = nil,
        prompt: String? = nil,
        subagentType: String? = nil
    ) {
        self.filePath = filePath
        self.command = command
        self.description = description
        self.pattern = pattern
        self.query = query
        self.url = url
        self.prompt = prompt
        self.subagentType = subagentType
    }
}

/// Wire-compatible with `trellis-card/src-tauri/src/session.rs::HookEvent` (camelCase JSON, NDJSON per line).
public struct HookEvent: Sendable, Codable, Equatable, Hashable {
    public var sessionId: String
    public var agentKind: String
    public var project: String
    public var taskId: String?
    public var eventName: String
    public var toolName: String?
    public var toolInput: ToolActivityInput?
    public var activity: String?
    public var action: TrellisAction?
    /// Unix timestamp in seconds.
    public var timestamp: Int64

    public var agent: AgentKind {
        AgentKind.from(raw: agentKind)
    }

    public init(
        sessionId: String,
        agentKind: String = "unknown",
        project: String,
        taskId: String? = nil,
        eventName: String,
        toolName: String? = nil,
        toolInput: ToolActivityInput? = nil,
        activity: String? = nil,
        action: TrellisAction? = nil,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.sessionId = sessionId
        self.agentKind = agentKind
        self.project = project
        self.taskId = taskId
        self.eventName = eventName
        self.toolName = toolName
        self.toolInput = toolInput
        self.activity = activity
        self.action = action
        self.timestamp = timestamp
    }
}

// MARK: - Activity Trace & Session State

public enum ActivityOutcome: String, Sendable, Codable, Equatable, Hashable {
    case running
    case succeeded
    case failed
    case waiting
    case info
}

public struct ActivityEntry: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String
    public var timestamp: Date
    public var agent: AgentKind
    public var sessionId: String
    public var projectPath: String
    public var taskId: String?
    public var toolName: String?
    public var summary: String
    public var targetPath: String?
    public var outcome: ActivityOutcome

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        agent: AgentKind,
        sessionId: String,
        projectPath: String,
        taskId: String? = nil,
        toolName: String? = nil,
        summary: String,
        targetPath: String? = nil,
        outcome: ActivityOutcome = .info
    ) {
        self.id = id
        self.timestamp = timestamp
        self.agent = agent
        self.sessionId = sessionId
        self.projectPath = projectPath
        self.taskId = taskId
        self.toolName = toolName
        self.summary = summary
        self.targetPath = targetPath
        self.outcome = outcome
    }
}

public struct AgentSessionState: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String { sessionId }
    public var sessionId: String
    public var agent: AgentKind
    public var projectPath: String
    public var taskId: String?
    public var status: RuntimeStatus
    public var eventName: String
    public var toolName: String?
    public var toolInput: ToolActivityInput?
    public var activity: String?
    public var lastAction: TrellisAction?
    public var startedAt: Date
    public var updatedAt: Date
    public var recentActivities: [ActivityEntry]

    public init(
        sessionId: String,
        agent: AgentKind,
        projectPath: String,
        taskId: String? = nil,
        status: RuntimeStatus = .idle,
        eventName: String = "",
        toolName: String? = nil,
        toolInput: ToolActivityInput? = nil,
        activity: String? = nil,
        lastAction: TrellisAction? = nil,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        recentActivities: [ActivityEntry] = []
    ) {
        self.sessionId = sessionId
        self.agent = agent
        self.projectPath = projectPath
        self.taskId = taskId
        self.status = status
        self.eventName = eventName
        self.toolName = toolName
        self.toolInput = toolInput
        self.activity = activity
        self.lastAction = lastAction
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.recentActivities = recentActivities
    }
}

public struct FocusSnapshot: Sendable, Codable, Equatable {
    public var focusedTaskKey: String?
    public var focusedProjectPath: String?
    public var focusedSessionId: String?
    public var status: RuntimeStatus
    public var attentionCount: Int
    public var activeSessions: [AgentSessionState]
    public var recentActivities: [ActivityEntry]
    public var updatedAt: Date

    public init(
        focusedTaskKey: String? = nil,
        focusedProjectPath: String? = nil,
        focusedSessionId: String? = nil,
        status: RuntimeStatus = .idle,
        attentionCount: Int = 0,
        activeSessions: [AgentSessionState] = [],
        recentActivities: [ActivityEntry] = [],
        updatedAt: Date = Date()
    ) {
        self.focusedTaskKey = focusedTaskKey
        self.focusedProjectPath = focusedProjectPath
        self.focusedSessionId = focusedSessionId
        self.status = status
        self.attentionCount = attentionCount
        self.activeSessions = activeSessions
        self.recentActivities = recentActivities
        self.updatedAt = updatedAt
    }
}
