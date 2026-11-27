import Foundation

// MARK: - Dynamic JSON Value

/// Type-safe, Sendable JSON value used for arbitrary `task.json` metadata (`meta`).
public enum AnyJSONValue: Sendable, Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyJSONValue])
    case object([String: AnyJSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnyJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }
}

// MARK: - Project Info

public struct ProjectInfo: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var activeTaskCount: Int
    public var archivedTaskCount: Int
    public var lastActivity: Date?

    public init(
        name: String,
        path: String,
        activeTaskCount: Int = 0,
        archivedTaskCount: Int = 0,
        lastActivity: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.activeTaskCount = activeTaskCount
        self.archivedTaskCount = archivedTaskCount
        self.lastActivity = lastActivity
    }
}

// MARK: - Task Subtasks (Canonical v0.7 String + Legacy Object)

public struct LegacySubtask: Sendable, Codable, Equatable, Hashable {
    public var name: String
    public var status: String?

    public init(name: String, status: String? = nil) {
        self.name = name
        self.status = status
    }
}

/// Supports both canonical Trellis v0.7 `subtasks: [String]` and legacy `[{name, status}]`.
public enum TaskSubtask: Sendable, Codable, Equatable, Hashable {
    case text(String)
    case legacy(LegacySubtask)

    public var name: String {
        switch self {
        case .text(let value): return value
        case .legacy(let item): return item.name
        }
    }

    public var status: String? {
        switch self {
        case .text: return nil
        case .legacy(let item): return item.status
        }
    }

    public var isCompleted: Bool {
        guard let status = status?.lowercased() else { return false }
        return status == "completed" || status == "done"
    }

    public init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let text = try? single.decode(String.self) {
            self = .text(text)
            return
        }
        let legacy = try single.decode(LegacySubtask.self)
        self = .legacy(legacy)
    }

    public func encode(to encoder: any Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try single.encode(text)
        case .legacy(let legacy):
            try single.encode(legacy)
        }
    }
}

// MARK: - Task Record (`task.json`)

/// Canonical Trellis `task.json` record with tolerant decoding for older partial records.
public struct TaskRecord: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var title: String
    public var description: String
    public var status: String
    public var devType: String?
    public var scope: String?
    public var package: String?
    public var priority: String
    public var creator: String?
    public var assignee: String?
    public var createdAt: String?
    public var completedAt: String?
    public var branch: String?
    public var baseBranch: String?
    public var worktreePath: String?
    public var commit: String?
    public var prUrl: String?
    public var subtasks: [TaskSubtask]
    public var children: [String]
    public var parent: String?
    public var relatedFiles: [String]
    public var notes: String
    public var meta: [String: AnyJSONValue]
    public var workflow: String?

    public init(
        id: String,
        name: String? = nil,
        title: String = "",
        description: String = "",
        status: String = "planning",
        devType: String? = nil,
        scope: String? = nil,
        package: String? = nil,
        priority: String = "P2",
        creator: String? = nil,
        assignee: String? = nil,
        createdAt: String? = nil,
        completedAt: String? = nil,
        branch: String? = nil,
        baseBranch: String? = nil,
        worktreePath: String? = nil,
        commit: String? = nil,
        prUrl: String? = nil,
        subtasks: [TaskSubtask] = [],
        children: [String] = [],
        parent: String? = nil,
        relatedFiles: [String] = [],
        notes: String = "",
        meta: [String: AnyJSONValue] = [:],
        workflow: String? = nil
    ) {
        self.id = id
        self.name = name ?? id
        self.title = title.isEmpty ? id : title
        self.description = description
        self.status = status
        self.devType = devType
        self.scope = scope
        self.package = package
        self.priority = priority
        self.creator = creator
        self.assignee = assignee
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.branch = branch
        self.baseBranch = baseBranch
        self.worktreePath = worktreePath
        self.commit = commit
        self.prUrl = prUrl
        self.subtasks = subtasks
        self.children = children
        self.parent = parent
        self.relatedFiles = relatedFiles
        self.notes = notes
        self.meta = meta
        self.workflow = workflow
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
        case description
        case status
        case devType = "dev_type"
        case devTypeCamel = "devType"
        case scope
        case package
        case priority
        case creator
        case assignee
        case createdAt
        case createdAtSnake = "created_at"
        case completedAt
        case completedAtSnake = "completed_at"
        case branch
        case baseBranch = "base_branch"
        case baseBranchCamel = "baseBranch"
        case worktreePath = "worktree_path"
        case worktreePathCamel = "worktreePath"
        case commit
        case prUrl = "pr_url"
        case prUrlCamel = "prUrl"
        case subtasks
        case children
        case parent
        case relatedFiles
        case relatedFilesSnake = "related_files"
        case notes
        case meta
        case workflow
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = try c.decodeIfPresent(String.self, forKey: .id)
        let decodedName = try c.decodeIfPresent(String.self, forKey: .name)
        let resolvedId = decodedId ?? decodedName ?? ""
        self.id = resolvedId
        self.name = decodedName ?? resolvedId
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? resolvedId
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "planning"
        self.devType = try c.decodeIfPresent(String.self, forKey: .devType)
            ?? c.decodeIfPresent(String.self, forKey: .devTypeCamel)
        self.scope = try c.decodeIfPresent(String.self, forKey: .scope)
        self.package = try c.decodeIfPresent(String.self, forKey: .package)
        self.priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? "P2"
        self.creator = try c.decodeIfPresent(String.self, forKey: .creator)
        self.assignee = try c.decodeIfPresent(String.self, forKey: .assignee)
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            ?? c.decodeIfPresent(String.self, forKey: .createdAtSnake)
        self.completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
            ?? c.decodeIfPresent(String.self, forKey: .completedAtSnake)
        self.branch = try c.decodeIfPresent(String.self, forKey: .branch)
        self.baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch)
            ?? c.decodeIfPresent(String.self, forKey: .baseBranchCamel)
        self.worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
            ?? c.decodeIfPresent(String.self, forKey: .worktreePathCamel)
        self.commit = try c.decodeIfPresent(String.self, forKey: .commit)
        self.prUrl = try c.decodeIfPresent(String.self, forKey: .prUrl)
            ?? c.decodeIfPresent(String.self, forKey: .prUrlCamel)
        self.subtasks = (try? c.decodeIfPresent([TaskSubtask].self, forKey: .subtasks)) ?? []
        self.children = (try? c.decodeIfPresent([String].self, forKey: .children)) ?? []
        self.parent = try c.decodeIfPresent(String.self, forKey: .parent)
        self.relatedFiles = (try? c.decodeIfPresent([String].self, forKey: .relatedFiles))
            ?? (try? c.decodeIfPresent([String].self, forKey: .relatedFilesSnake))
            ?? []
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.meta = (try? c.decodeIfPresent([String: AnyJSONValue].self, forKey: .meta)) ?? [:]
        self.workflow = try c.decodeIfPresent(String.self, forKey: .workflow)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(devType, forKey: .devType)
        try c.encodeIfPresent(scope, forKey: .scope)
        try c.encodeIfPresent(package, forKey: .package)
        try c.encode(priority, forKey: .priority)
        try c.encodeIfPresent(creator, forKey: .creator)
        try c.encodeIfPresent(assignee, forKey: .assignee)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(branch, forKey: .branch)
        try c.encodeIfPresent(baseBranch, forKey: .baseBranch)
        try c.encodeIfPresent(worktreePath, forKey: .worktreePath)
        try c.encodeIfPresent(commit, forKey: .commit)
        try c.encodeIfPresent(prUrl, forKey: .prUrl)
        try c.encode(subtasks, forKey: .subtasks)
        try c.encode(children, forKey: .children)
        try c.encodeIfPresent(parent, forKey: .parent)
        try c.encode(relatedFiles, forKey: .relatedFiles)
        try c.encode(notes, forKey: .notes)
        try c.encode(meta, forKey: .meta)
        try c.encodeIfPresent(workflow, forKey: .workflow)
    }
}

// MARK: - Workflow Phase, Checklists, Artifacts & Snapshot

public enum WorkflowPhase: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case explore
    case plan
    case implement
    case check
    case archive

    public var label: String {
        switch self {
        case .explore: return "Explore"
        case .plan: return "Plan"
        case .implement: return "Implement"
        case .check: return "Check"
        case .archive: return "Archive"
        }
    }

    public var order: Int {
        switch self {
        case .explore: return 0
        case .plan: return 1
        case .implement: return 2
        case .check: return 3
        case .archive: return 4
        }
    }
}

public struct ChecklistItem: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String
    public var text: String
    public var isCompleted: Bool
    public var sourceFile: String
    public var lineNumber: Int
    public var section: String?

    public init(
        id: String? = nil,
        text: String,
        isCompleted: Bool,
        sourceFile: String,
        lineNumber: Int,
        section: String? = nil
    ) {
        self.id = id ?? "\(sourceFile):\(lineNumber)"
        self.text = text
        self.isCompleted = isCompleted
        self.sourceFile = sourceFile
        self.lineNumber = lineNumber
        self.section = section
    }
}

public struct TaskArtifacts: Sendable, Codable, Equatable, Hashable {
    public var hasPrd: Bool
    public var hasDesign: Bool
    public var hasImplement: Bool
    public var researchCount: Int
    public var implContextCount: Int
    public var checkContextCount: Int
    public var reportCount: Int
    public var documentPaths: [String]
    public var specRefs: [String]
    public var fileRefs: [String]
    public var prdRefs: [String]

    public init(
        hasPrd: Bool = false,
        hasDesign: Bool = false,
        hasImplement: Bool = false,
        researchCount: Int = 0,
        implContextCount: Int = 0,
        checkContextCount: Int = 0,
        reportCount: Int = 0,
        documentPaths: [String] = [],
        specRefs: [String] = [],
        fileRefs: [String] = [],
        prdRefs: [String] = []
    ) {
        self.hasPrd = hasPrd
        self.hasDesign = hasDesign
        self.hasImplement = hasImplement
        self.researchCount = researchCount
        self.implContextCount = implContextCount
        self.checkContextCount = checkContextCount
        self.reportCount = reportCount
        self.documentPaths = documentPaths
        self.specRefs = specRefs
        self.fileRefs = fileRefs
        self.prdRefs = prdRefs
    }
}

public struct TaskSnapshot: Sendable, Codable, Equatable, Identifiable, Hashable {
    /// Stable identity key: `<projectPath>::<dir>`.
    public var id: String
    public var projectName: String
    public var projectPath: String
    /// Directory relative to `.trellis/tasks/` (e.g. `10-22-foo` or `archive/2026-10/10-22-foo`).
    public var dir: String
    public var archived: Bool
    public var record: TaskRecord
    public var phase: WorkflowPhase
    public var phaseWarning: String?
    public var checklist: [ChecklistItem]
    public var progress: Double
    public var artifacts: TaskArtifacts
    public var excerpt: String
    public var mtime: Date
    public var activeSessionIds: [String]

    public var completedChecklistCount: Int {
        checklist.filter(\.isCompleted).count
    }

    public var totalChecklistCount: Int {
        checklist.count
    }

    public var isDone: Bool {
        archived || record.status == "completed" || record.status == "done"
    }

    public init(
        projectName: String,
        projectPath: String,
        dir: String,
        archived: Bool = false,
        record: TaskRecord,
        phase: WorkflowPhase = .explore,
        phaseWarning: String? = nil,
        checklist: [ChecklistItem] = [],
        progress: Double = 0.0,
        artifacts: TaskArtifacts = TaskArtifacts(),
        excerpt: String = "",
        mtime: Date = .distantPast,
        activeSessionIds: [String] = []
    ) {
        self.id = "\(projectPath)::\(dir)"
        self.projectName = projectName
        self.projectPath = projectPath
        self.dir = dir
        self.archived = archived
        self.record = record
        self.phase = phase
        self.phaseWarning = phaseWarning
        self.checklist = checklist
        self.progress = progress
        self.artifacts = artifacts
        self.excerpt = excerpt
        self.mtime = mtime
        self.activeSessionIds = activeSessionIds
    }
}

// MARK: - HUD Presentation & Config

public enum PresentationMode: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case notch
    case edgePill
}

public enum EdgeAnchor: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case left
    case right
    case bottomRight
    case bottomLeft
}

/// Compatible with `~/.config/trellis-card/config.json` plus new native HUD preferences.
public struct HUDConfig: Sendable, Codable, Equatable {
    public var roots: [String]
    public var dynamicProjects: [String]
    public var initialized: Bool
    public var alwaysOnTop: Bool
    public var wslDistro: String?
    public var presentationMode: PresentationMode
    public var edgeAnchor: EdgeAnchor
    public var edgeVerticalRatio: Double
    public var autoFollowFocus: Bool
    public var showArchived: Bool
    public var selectedProjectPath: String?
    public var launchAtLogin: Bool

    public init(
        roots: [String] = [],
        dynamicProjects: [String] = [],
        initialized: Bool = false,
        alwaysOnTop: Bool = true,
        wslDistro: String? = nil,
        presentationMode: PresentationMode = .notch,
        edgeAnchor: EdgeAnchor = .right,
        edgeVerticalRatio: Double = 0.35,
        autoFollowFocus: Bool = true,
        showArchived: Bool = false,
        selectedProjectPath: String? = nil,
        launchAtLogin: Bool = false
    ) {
        self.roots = roots
        self.dynamicProjects = dynamicProjects
        self.initialized = initialized
        self.alwaysOnTop = alwaysOnTop
        self.wslDistro = wslDistro
        self.presentationMode = presentationMode
        self.edgeAnchor = edgeAnchor
        self.edgeVerticalRatio = edgeVerticalRatio
        self.autoFollowFocus = autoFollowFocus
        self.showArchived = showArchived
        self.selectedProjectPath = selectedProjectPath
        self.launchAtLogin = launchAtLogin
    }

    private enum CodingKeys: String, CodingKey {
        case roots
        case dynamicProjects
        case initialized
        case alwaysOnTop
        case wslDistro
        case presentationMode
        case edgeAnchor
        case edgeVerticalRatio
        case autoFollowFocus
        case showArchived
        case selectedProjectPath
        case launchAtLogin
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? []
        self.dynamicProjects = try c.decodeIfPresent([String].self, forKey: .dynamicProjects) ?? []
        self.initialized = try c.decodeIfPresent(Bool.self, forKey: .initialized) ?? false
        self.alwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? true
        self.wslDistro = try c.decodeIfPresent(String.self, forKey: .wslDistro)
        self.presentationMode = try c.decodeIfPresent(PresentationMode.self, forKey: .presentationMode) ?? .notch
        self.edgeAnchor = try c.decodeIfPresent(EdgeAnchor.self, forKey: .edgeAnchor) ?? .right
        self.edgeVerticalRatio = try c.decodeIfPresent(Double.self, forKey: .edgeVerticalRatio) ?? 0.35
        self.autoFollowFocus = try c.decodeIfPresent(Bool.self, forKey: .autoFollowFocus) ?? true
        self.showArchived = try c.decodeIfPresent(Bool.self, forKey: .showArchived) ?? false
        self.selectedProjectPath = try c.decodeIfPresent(String.self, forKey: .selectedProjectPath)
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    }
}
