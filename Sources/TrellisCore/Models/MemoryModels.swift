import Foundation

// MARK: - Spec Documents (3-level monorepo + path globs)

public struct SpecDocument: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String { relativePath }
    /// Path relative to project root (e.g. `.trellis/spec/cli/backend/auth.md`).
    public var relativePath: String
    public var absolutePath: String
    public var name: String
    public var category: String
    public var packageName: String?
    public var layer: String?
    public var lineCount: Int
    public var isEmptyTemplate: Bool
    public var pathGlobs: [String]
    public var matchedModifiedFiles: [String]
    public var referencedByTaskCount: Int
    public var content: String

    public init(
        relativePath: String,
        absolutePath: String,
        name: String,
        category: String,
        packageName: String? = nil,
        layer: String? = nil,
        lineCount: Int = 0,
        isEmptyTemplate: Bool = false,
        pathGlobs: [String] = [],
        matchedModifiedFiles: [String] = [],
        referencedByTaskCount: Int = 0,
        content: String = ""
    ) {
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.name = name
        self.category = category
        self.packageName = packageName
        self.layer = layer
        self.lineCount = lineCount
        self.isEmptyTemplate = isEmptyTemplate
        self.pathGlobs = pathGlobs
        self.matchedModifiedFiles = matchedModifiedFiles
        self.referencedByTaskCount = referencedByTaskCount
        self.content = content
    }
}

// MARK: - Git Status & Diff Snapshot

public enum GitChangeKind: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case modified
    case added
    case deleted
    case renamed
    case untracked
    case conflicted
}

public struct GitFileChange: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String { "\(path)::\(isStaged)::\(isUnstaged)" }
    public var path: String
    public var originalPath: String?
    public var kind: GitChangeKind
    public var isStaged: Bool
    public var isUnstaged: Bool

    public init(
        path: String,
        originalPath: String? = nil,
        kind: GitChangeKind,
        isStaged: Bool = false,
        isUnstaged: Bool = false
    ) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
        self.isStaged = isStaged
        self.isUnstaged = isUnstaged
    }
}

public struct GitStatusSnapshot: Sendable, Codable, Equatable, Hashable {
    public var projectPath: String
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var isDetachedHead: Bool
    public var isWorktree: Bool
    public var worktreePath: String?
    public var changes: [GitFileChange]
    public var capturedAt: Date

    public var isClean: Bool { changes.isEmpty }
    public var modifiedPaths: [String] { changes.map(\.path) }

    public init(
        projectPath: String,
        branch: String? = nil,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        isDetachedHead: Bool = false,
        isWorktree: Bool = false,
        worktreePath: String? = nil,
        changes: [GitFileChange] = [],
        capturedAt: Date = Date()
    ) {
        self.projectPath = projectPath
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.isDetachedHead = isDetachedHead
        self.isWorktree = isWorktree
        self.worktreePath = worktreePath
        self.changes = changes
        self.capturedAt = capturedAt
    }
}

// MARK: - Workspace Journals & Cross-Platform Session Memory (`trellis mem`)

public struct WorkspaceJournal: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String { filePath }
    public var developer: String
    public var fileName: String
    public var filePath: String
    public var indexNumber: Int
    public var lineCount: Int
    public var mtime: Date
    public var latestHeading: String?
    public var preview: String
    public var content: String

    public init(
        developer: String,
        fileName: String,
        filePath: String,
        indexNumber: Int = 1,
        lineCount: Int = 0,
        mtime: Date = .distantPast,
        latestHeading: String? = nil,
        preview: String = "",
        content: String = ""
    ) {
        self.developer = developer
        self.fileName = fileName
        self.filePath = filePath
        self.indexNumber = indexNumber
        self.lineCount = lineCount
        self.mtime = mtime
        self.latestHeading = latestHeading
        self.preview = preview
        self.content = content
    }
}

public enum MemoryPlatform: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case antigravity
    case claude
    case codex
    case devin
    case grok
    case opencode
    case pi
    case zcode
    case unknown

    public static func from(raw: String) -> MemoryPlatform {
        MemoryPlatform(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .unknown
    }
}

public struct MemoryExcerpt: Sendable, Codable, Equatable, Hashable {
    public var role: String
    public var snippet: String

    public init(role: String, snippet: String) {
        self.role = role
        self.snippet = snippet
    }
}

public struct MemorySessionItem: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String
    public var platform: MemoryPlatform
    public var title: String?
    public var cwd: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var filePath: String
    public var parentId: String?
    public var score: Double?
    public var matchCount: Int
    public var excerpts: [MemoryExcerpt]

    public init(
        id: String,
        platform: MemoryPlatform,
        title: String? = nil,
        cwd: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        filePath: String,
        parentId: String? = nil,
        score: Double? = nil,
        matchCount: Int = 0,
        excerpts: [MemoryExcerpt] = []
    ) {
        self.id = id
        self.platform = platform
        self.title = title
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.filePath = filePath
        self.parentId = parentId
        self.score = score
        self.matchCount = matchCount
        self.excerpts = excerpts
    }
}

// MARK: - Task / Worker Action Result

public enum ActionKind: String, Sendable, Codable, Equatable, Hashable {
    case validate
    case start
    case archive
    case interruptWorker
    case killWorker
    case custom
}

public struct ActionResult: Sendable, Codable, Equatable, Hashable {
    public var success: Bool
    public var action: ActionKind
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var message: String
    public var durationMs: Int

    public init(
        success: Bool,
        action: ActionKind,
        exitCode: Int32 = 0,
        stdout: String = "",
        stderr: String = "",
        message: String = "",
        durationMs: Int = 0
    ) {
        self.success = success
        self.action = action
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.message = message
        self.durationMs = durationMs
    }
}
