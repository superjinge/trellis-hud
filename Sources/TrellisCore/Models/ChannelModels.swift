import Foundation

// MARK: - Trellis Channel Schema Models
// Modeled directly after `Trellis/packages/core/src/channel/internal/store/{schema,events,worker-state,thread-state}.ts`.

public enum ChannelScope: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case project
    case global
}

public enum ChannelType: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case chat
    case forum
}

public enum ChannelInboxPolicy: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case explicitOnly
    case broadcastAndExplicit
}

public enum ChannelWorkerLifecycle: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case starting
    case running
    case done
    case error
    case killed
    case crashed

    public var isTerminal: Bool {
        switch self {
        case .done, .error, .killed, .crashed:
            return true
        case .starting, .running:
            return false
        }
    }
}

public enum ChannelWorkerActivity: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case idle
    case midTurn = "mid-turn"
}

public enum ChannelContextEntry: Sendable, Codable, Equatable, Hashable {
    case file(path: String)
    case raw(text: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case path
        case text
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .type)
        switch kind {
        case "file":
            self = .file(path: try c.decode(String.self, forKey: .path))
        case "raw":
            self = .raw(text: try c.decode(String.self, forKey: .text))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Unknown channel context entry type: \(kind)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .file(let path):
            try c.encode("file", forKey: .type)
            try c.encode(path, forKey: .path)
        case .raw(let text):
            try c.encode("raw", forKey: .type)
            try c.encode(text, forKey: .text)
        }
    }
}

public struct ChannelWorkerState: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String { "\(channelName)::\(workerId)" }
    public var workerId: String
    public var channelName: String
    public var agent: String?
    public var provider: String?
    public var lifecycle: ChannelWorkerLifecycle
    public var activity: ChannelWorkerActivity
    public var activeTurnId: String?
    public var activeTurnStartedAt: Date?
    public var pendingMessageCount: Int
    public var inboxPolicy: ChannelInboxPolicy
    public var spawnedAt: Date?
    public var updatedAt: Date
    public var startedBy: String?
    public var exitCode: Int?
    public var signal: String?
    public var reason: String?
    public var lastError: String?
    public var idleSince: Date?
    public var lastSeq: Int

    public var isTerminal: Bool { lifecycle.isTerminal }

    public init(
        workerId: String,
        channelName: String,
        agent: String? = nil,
        provider: String? = nil,
        lifecycle: ChannelWorkerLifecycle = .running,
        activity: ChannelWorkerActivity = .idle,
        activeTurnId: String? = nil,
        activeTurnStartedAt: Date? = nil,
        pendingMessageCount: Int = 0,
        inboxPolicy: ChannelInboxPolicy = .explicitOnly,
        spawnedAt: Date? = nil,
        updatedAt: Date = Date(),
        startedBy: String? = nil,
        exitCode: Int? = nil,
        signal: String? = nil,
        reason: String? = nil,
        lastError: String? = nil,
        idleSince: Date? = nil,
        lastSeq: Int = 0
    ) {
        self.workerId = workerId
        self.channelName = channelName
        self.agent = agent
        self.provider = provider
        self.lifecycle = lifecycle
        self.activity = activity
        self.activeTurnId = activeTurnId
        self.activeTurnStartedAt = activeTurnStartedAt
        self.pendingMessageCount = pendingMessageCount
        self.inboxPolicy = inboxPolicy
        self.spawnedAt = spawnedAt
        self.updatedAt = updatedAt
        self.startedBy = startedBy
        self.exitCode = exitCode
        self.signal = signal
        self.reason = reason
        self.lastError = lastError
        self.idleSince = idleSince
        self.lastSeq = lastSeq
    }
}

public struct ChannelThread: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String { thread }
    public var thread: String
    public var title: String?
    public var status: String
    public var labels: [String]
    public var assignees: [String]
    public var description: String?
    public var summary: String?
    public var context: [ChannelContextEntry]
    public var openedAt: Date?
    public var updatedAt: Date?
    public var lastSeq: Int
    public var comments: Int
    public var aliases: [String]

    public init(
        thread: String,
        title: String? = nil,
        status: String = "open",
        labels: [String] = [],
        assignees: [String] = [],
        description: String? = nil,
        summary: String? = nil,
        context: [ChannelContextEntry] = [],
        openedAt: Date? = nil,
        updatedAt: Date? = nil,
        lastSeq: Int = 0,
        comments: Int = 0,
        aliases: [String] = []
    ) {
        self.thread = thread
        self.title = title
        self.status = status
        self.labels = labels
        self.assignees = assignees
        self.description = description
        self.summary = summary
        self.context = context
        self.openedAt = openedAt
        self.updatedAt = updatedAt
        self.lastSeq = lastSeq
        self.comments = comments
        self.aliases = aliases
    }
}

public struct ChannelMessage: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String { "\(channelName)#\(seq)" }
    public var channelName: String
    public var seq: Int
    public var timestamp: Date
    public var kind: String
    public var by: String
    public var to: [String]
    public var text: String
    public var thread: String?
    public var origin: String?

    public init(
        channelName: String,
        seq: Int,
        timestamp: Date,
        kind: String,
        by: String,
        to: [String] = [],
        text: String = "",
        thread: String? = nil,
        origin: String? = nil
    ) {
        self.channelName = channelName
        self.seq = seq
        self.timestamp = timestamp
        self.kind = kind
        self.by = by
        self.to = to
        self.text = text
        self.thread = thread
        self.origin = origin
    }
}

public struct ChannelInfo: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String { "\(projectKey)/\(name)" }
    public var name: String
    public var scope: ChannelScope
    public var projectKey: String
    public var dirPath: String
    public var type: ChannelType
    public var title: String?
    public var description: String?
    public var taskRef: String?
    public var cwd: String?
    public var labels: [String]
    public var context: [ChannelContextEntry]
    public var workers: [ChannelWorkerState]
    public var threads: [ChannelThread]
    public var recentMessages: [ChannelMessage]
    public var lastSeq: Int
    public var updatedAt: Date?

    public var activeWorkers: [ChannelWorkerState] {
        workers.filter { !$0.isTerminal }
    }

    public init(
        name: String,
        scope: ChannelScope = .project,
        projectKey: String,
        dirPath: String,
        type: ChannelType = .chat,
        title: String? = nil,
        description: String? = nil,
        taskRef: String? = nil,
        cwd: String? = nil,
        labels: [String] = [],
        context: [ChannelContextEntry] = [],
        workers: [ChannelWorkerState] = [],
        threads: [ChannelThread] = [],
        recentMessages: [ChannelMessage] = [],
        lastSeq: Int = 0,
        updatedAt: Date? = nil
    ) {
        self.name = name
        self.scope = scope
        self.projectKey = projectKey
        self.dirPath = dirPath
        self.type = type
        self.title = title
        self.description = description
        self.taskRef = taskRef
        self.cwd = cwd
        self.labels = labels
        self.context = context
        self.workers = workers
        self.threads = threads
        self.recentMessages = recentMessages
        self.lastSeq = lastSeq
        self.updatedAt = updatedAt
    }
}
