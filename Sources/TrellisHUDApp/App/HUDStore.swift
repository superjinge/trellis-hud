import AppKit
import Foundation
import Observation
import TrellisCore

// MARK: - Supporting UI Contracts

public enum WorkbenchTab: String, CaseIterable, Identifiable, Sendable {
    case flow
    case live
    case docsSpecs
    case history

    public var id: String { rawValue }

    public var title: String {
        L10n(language: .system).tabTitle(self)
    }

    public var systemImage: String {
        switch self {
        case .flow: return "point.3.connected.trianglepath.dotted"
        case .live: return "waveform.path.ecg"
        case .docsSpecs: return "doc.text.magnifyingglass"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

public enum DocsSubMode: String, CaseIterable, Identifiable, Sendable {
    case taskDocs
    case projectSpecs

    public var id: String { rawValue }
}

public struct StatusToast: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let message: String
    public let isError: Bool

    public init(id: UUID = UUID(), message: String, isError: Bool = false) {
        self.id = id
        self.message = message
        self.isError = isError
    }
}

public struct AgentHookStatusInfo: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { agent.rawValue }
    public var agent: AgentKind
    public var installed: Bool
    public var configExists: Bool
    public var configPath: String
    public var isSupported: Bool
    public var detail: String?

    public init(
        agent: AgentKind,
        installed: Bool,
        configExists: Bool,
        configPath: String,
        isSupported: Bool = true,
        detail: String? = nil
    ) {
        self.agent = agent
        self.installed = installed
        self.configExists = configExists
        self.configPath = configPath
        self.isSupported = isSupported
        self.detail = detail
    }
}

// MARK: - Pluggable Backend Provider (wired to TrellisCore Scanner / Runtime / IPC)

public struct HUDDataProvider: Sendable {
    public var loadConfig: @Sendable () -> HUDConfig
    public var saveConfig: @Sendable (HUDConfig) throws -> Void
    public var discoverProjects: @Sendable ([String], [String]) -> [ProjectInfo]
    public var scanActiveTasks: @Sendable (String) -> [TaskSnapshot]
    public var scanArchivedTasks: @Sendable (String) -> [TaskSnapshot]
    public var loadDocument: @Sendable (String, String) -> String?
    public var scanSpecsAndGit: @Sendable (String, [String]) -> ([SpecDocument], GitStatusSnapshot?)
    public var scanChannels: @Sendable () -> [ChannelInfo]
    public var scanJournals: @Sendable (String) -> [WorkspaceJournal]
    public var searchMemory: @Sendable (String, String?) -> [MemorySessionItem]
    public var runTaskAction: @Sendable (ActionKind, String, String) async -> ActionResult
    public var getHookStatuses: @Sendable () -> [AgentHookStatusInfo]
    public var configureHook: @Sendable (AgentKind, Bool) throws -> AgentHookStatusInfo

    public init(
        loadConfig: @escaping @Sendable () -> HUDConfig,
        saveConfig: @escaping @Sendable (HUDConfig) throws -> Void,
        discoverProjects: @escaping @Sendable ([String], [String]) -> [ProjectInfo],
        scanActiveTasks: @escaping @Sendable (String) -> [TaskSnapshot],
        scanArchivedTasks: @escaping @Sendable (String) -> [TaskSnapshot],
        loadDocument: @escaping @Sendable (String, String) -> String?,
        scanSpecsAndGit: @escaping @Sendable (String, [String]) -> ([SpecDocument], GitStatusSnapshot?),
        scanChannels: @escaping @Sendable () -> [ChannelInfo],
        scanJournals: @escaping @Sendable (String) -> [WorkspaceJournal],
        searchMemory: @escaping @Sendable (String, String?) -> [MemorySessionItem],
        runTaskAction: @escaping @Sendable (ActionKind, String, String) async -> ActionResult,
        getHookStatuses: @escaping @Sendable () -> [AgentHookStatusInfo],
        configureHook: @escaping @Sendable (AgentKind, Bool) throws -> AgentHookStatusInfo
    ) {
        self.loadConfig = loadConfig
        self.saveConfig = saveConfig
        self.discoverProjects = discoverProjects
        self.scanActiveTasks = scanActiveTasks
        self.scanArchivedTasks = scanArchivedTasks
        self.loadDocument = loadDocument
        self.scanSpecsAndGit = scanSpecsAndGit
        self.scanChannels = scanChannels
        self.scanJournals = scanJournals
        self.searchMemory = searchMemory
        self.runTaskAction = runTaskAction
        self.getHookStatuses = getHookStatuses
        self.configureHook = configureHook
    }

    /// Production data provider wired directly to all `TrellisCore` Scanner, Runtime, and IPC engines.
    public static func live(
        configStore: ConfigStore = ConfigStore(),
        actionRunner: TaskActionRunner = TaskActionRunner()
    ) -> HUDDataProvider {
        let installer = HookInstaller(configStore: configStore)
        return HUDDataProvider(
            loadConfig: { configStore.load() },
            saveConfig: { try configStore.save($0) },
            discoverProjects: { roots, dynamicProjects in
                var projects = ProjectScanner.discoverProjects(roots: roots, maxDepth: 3)
                var seen = Set(projects.map(\.path))
                for rawPath in dynamicProjects {
                    let normalized = ConfigStore.normalizePath(rawPath)
                    guard !seen.contains(normalized) else { continue }
                    let tasksDir = URL(fileURLWithPath: normalized).appendingPathComponent(".trellis/tasks").path
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: tasksDir, isDirectory: &isDir), isDir.boolValue {
                        seen.insert(normalized)
                        projects.append(ProjectScanner.scanProjectInfo(projectPath: normalized))
                    }
                }
                return projects.sorted { lhs, rhs in
                    let lDate = lhs.lastActivity ?? .distantPast
                    let rDate = rhs.lastActivity ?? .distantPast
                    if lDate != rDate { return lDate > rDate }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            },
            scanActiveTasks: { projectPath in
                ProjectScanner.scanActiveTasks(projectPath: projectPath)
            },
            scanArchivedTasks: { projectPath in
                ProjectScanner.scanArchivedTasks(projectPath: projectPath)
            },
            loadDocument: { taskDir, relativePath in
                ProjectScanner.loadTaskDocument(taskDir: taskDir, relativePath: relativePath)
            },
            scanSpecsAndGit: { projectPath, specRefs in
                let report = SpecAndGitAnalyzer.analyzeGovernance(
                    projectPath: projectPath,
                    referencedSpecPaths: specRefs
                )
                return (report.specs, report.gitStatus)
            },
            scanChannels: {
                ChannelReader.scanChannels(projectPath: nil, includeEphemeral: false, maxRecentMessages: 50)
            },
            scanJournals: { projectPath in
                MemoryReader.scanJournals(projectPath: projectPath)
            },
            searchMemory: { query, projectPath in
                MemoryReader.searchMemory(query: query, projectPath: projectPath, limit: 35)
            },
            runTaskAction: { action, projectPath, taskDir in
                switch action {
                case .validate:
                    return await actionRunner.validateTask(projectPath: projectPath, taskDir: taskDir)
                case .start:
                    return await actionRunner.startTask(projectPath: projectPath, taskDir: taskDir)
                case .archive:
                    return await actionRunner.archiveTask(projectPath: projectPath, taskDir: taskDir)
                default:
                    return ActionResult(success: false, action: action, exitCode: 1, message: "Unsupported action")
                }
            },
            getHookStatuses: {
                installer.allStatuses().map { st in
                    AgentHookStatusInfo(
                        agent: st.agent,
                        installed: st.installed,
                        configExists: st.configExists,
                        configPath: st.configPath,
                        isSupported: true,
                        detail: st.agent == .antigravity ? "Hooks + trellis mem" : nil
                    )
                }
            },
            configureHook: { agent, enabled in
                _ = try installer.install(agent: agent, uninstall: !enabled)
                let st = installer.status(for: agent)
                return AgentHookStatusInfo(
                    agent: st.agent,
                    installed: st.installed,
                    configExists: st.configExists,
                    configPath: st.configPath,
                    isSupported: true,
                    detail: st.agent == .antigravity ? "Hooks + trellis mem" : nil
                )
            }
        )
    }
}

// MARK: - HUDStore

@Observable
@MainActor
public final class HUDStore {
    // MARK: Presentation & Window State

    public var config: HUDConfig
    public var isExpanded: Bool = false
    public var isHovered: Bool = false
    public var isSettingsOpen: Bool = false
    public var selectedTab: WorkbenchTab = .flow
    public var docsSubMode: DocsSubMode = .taskDocs
    public var showMenuBarIcon: Bool
    public var workbenchSize: CGSize

    public var language: AppLanguage {
        config.language
    }

    public var l10n: L10n {
        L10n(language: config.language)
    }

    public var presentationMode: PresentationMode {
        config.presentationMode
    }

    public var edgeAnchor: EdgeAnchor {
        config.edgeAnchor
    }

    public var edgeVerticalRatio: Double {
        config.edgeVerticalRatio
    }

    public var autoFollowFocus: Bool {
        config.autoFollowFocus
    }

    public var watchedRoots: [String] {
        config.roots
    }

    // MARK: Workspace & Task State (Tab 1: Flow + Tab 3: Docs & Specs + Tab 4: History)

    public var projects: [ProjectInfo] = []
    public var selectedProjectPath: String?

    public var activeTasks: [TaskSnapshot] = []
    public var archivedTasks: [TaskSnapshot] = []
    public var selectedTaskId: String?

    public var specs: [SpecDocument] = []
    public var gitStatus: GitStatusSnapshot?

    public var selectedDocPath: String?
    public var selectedDocContent: String = ""
    public var isLoadingDoc: Bool = false

    public var selectedSpecPath: String?

    public var journals: [WorkspaceJournal] = []
    public var memorySessions: [MemorySessionItem] = []
    public var historyQuery: String = ""
    public var isLoadingHistory: Bool = false

    // MARK: Live Runtime & Channels (Tab 2: Live + Ambient)

    public var focusSnapshot: FocusSnapshot = FocusSnapshot()
    public var activeSessions: [AgentSessionState] = []
    public var recentActivities: [ActivityEntry] = []
    public var channels: [ChannelInfo] = []
    public var selectedChannelId: String?

    // MARK: Hooks, Actions & UI Feedback

    public var hookStatuses: [AgentHookStatusInfo] = []
    public var updatingHookAgent: AgentKind?
    public var isRefreshing: Bool = false
    public var runningAction: ActionKind?
    public var lastActionResult: ActionResult?
    public var statusToast: StatusToast?

    // MARK: App Shell Callbacks (wired by AppDelegate / HUDPanelController)

    public var onPresentationModeChanged: ((PresentationMode) -> Void)?
    public var onExpansionChanged: ((Bool) -> Void)?
    public var onEdgeAnchorChanged: ((EdgeAnchor) -> Void)?
    public var onMenuBarVisibilityChanged: ((Bool) -> Void)?
    public var onLanguageChanged: ((L10n) -> Void)?
    public var onWatchedPathsChanged: (([String]) -> Void)?
    public var onAttentionAlert: ((AgentSessionState) -> Void)?
    public var onJumpToTerminal: ((AgentKind?, String?) -> Void)?
    public var onModalPresentationChanged: ((Bool) -> Void)?

    // MARK: Internal State

    private let provider: HUDDataProvider
    private var toastDismissTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var projectDetailTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var sessionRegistry: SessionRegistry = SessionRegistry()
    private var alertedSessionTimestamps: [String: Date] = [:]
    private var historyLoadedForProject: String?
    private var historyDirty: Bool = true
    private var lastLoadedDocTaskDir: String?

    private static let showMenuBarIconDefaultsKey = "trellisHUD.showMenuBarIcon"
    private static let workbenchWidthDefaultsKey = "trellisHUD.workbenchWidth"
    private static let workbenchHeightDefaultsKey = "trellisHUD.workbenchHeight"
    private static let maxActivityHistory = 60

    // MARK: Init

    public init(provider: HUDDataProvider = .live()) {
        self.provider = provider
        let loaded = provider.loadConfig()
        self.config = loaded
        self.selectedProjectPath = loaded.selectedProjectPath
        if UserDefaults.standard.object(forKey: Self.showMenuBarIconDefaultsKey) != nil {
            self.showMenuBarIcon = UserDefaults.standard.bool(forKey: Self.showMenuBarIconDefaultsKey)
        } else {
            self.showMenuBarIcon = true
        }
        let savedW = UserDefaults.standard.double(forKey: Self.workbenchWidthDefaultsKey)
        let savedH = UserDefaults.standard.double(forKey: Self.workbenchHeightDefaultsKey)
        self.workbenchSize = CGSize(
            width: savedW >= 640 ? savedW : 840,
            height: savedH >= 420 ? savedH : 580
        )
        // Hook statuses are loaded asynchronously on launch / Settings open to keep init non-blocking.
    }

    // MARK: Derived Properties for UI

    public var selectedProject: ProjectInfo? {
        if let path = selectedProjectPath, let match = projects.first(where: { $0.path == path }) {
            return match
        }
        return projects.first
    }

    public var selectedTask: TaskSnapshot? {
        if let id = selectedTaskId, let match = activeTasks.first(where: { $0.id == id }) {
            return match
        }
        return activeTasks.first
    }

    public var selectedSpec: SpecDocument? {
        if let path = selectedSpecPath, let match = specs.first(where: { $0.relativePath == path }) {
            return match
        }
        return specs.first
    }

    public var selectedChannel: ChannelInfo? {
        if let id = selectedChannelId, let match = channels.first(where: { $0.id == id }) {
            return match
        }
        return channels.first
    }

    public var attentionSessions: [AgentSessionState] {
        activeSessions.filter { $0.status.isAttentionRequired }
    }

    public var attentionCount: Int {
        attentionSessions.count
    }

    public var activeAgentCount: Int {
        activeSessions.filter { $0.status == .working || $0.status.isAttentionRequired }.count
    }

    public var globalStatus: RuntimeStatus {
        if let top = activeSessions.max(by: { lhs, rhs in
            if lhs.status.priorityRank != rhs.status.priorityRank {
                return lhs.status.priorityRank < rhs.status.priorityRank
            }
            return lhs.updatedAt < rhs.updatedAt
        }) {
            return top.status
        }
        if let task = selectedTask {
            return task.isDone ? .done : .idle
        }
        return .idle
    }

    public var ambientPhaseLabel: String {
        let loc = l10n
        if let alert = attentionSessions.first {
            return loc.statusLabel(alert.status)
        }
        guard let task = selectedTask else {
            return activeAgentCount > 0 ? loc.statusLabel(.working) : loc.statusLabel(.idle)
        }
        let shortPhase = loc.shortPhaseLabel(task.phase)
        if task.totalChecklistCount > 0 {
            return "\(shortPhase) \(task.completedChecklistCount)/\(task.totalChecklistCount)"
        }
        return shortPhase
    }

    public var ambientTaskTitle: String {
        if let task = selectedTask {
            return task.record.title.isEmpty ? task.dir : task.record.title
        }
        if let project = selectedProject {
            return project.name
        }
        return "Trellis HUD"
    }

    /// Activities scoped to the currently selected task/project (falls back to global recent activities).
    public var currentTaskActivities: [ActivityEntry] {
        guard let task = selectedTask else { return recentActivities }
        let taskMatches = recentActivities.filter { entry in
            entry.projectPath == task.projectPath && (entry.taskId == task.dir || entry.taskId == task.record.id)
        }
        if !taskMatches.isEmpty { return taskMatches }
        let projectMatches = recentActivities.filter { $0.projectPath == task.projectPath }
        return projectMatches.isEmpty ? recentActivities : projectMatches
    }

    /// Specs that cover the given modified file path.
    public func specsForModifiedFile(_ relativePath: String) -> [SpecDocument] {
        specs.filter { $0.matchedModifiedFiles.contains(relativePath) }
    }

    /// Modified git files with zero matching `.trellis/spec/` path globs (ignoring `.trellis/` metadata files).
    public var uncoveredModifiedFiles: [String] {
        guard let git = gitStatus else { return [] }
        let covered = Set(specs.flatMap(\.matchedModifiedFiles))
        return git.modifiedPaths.filter { path in
            let norm = path.replacingOccurrences(of: "\\", with: "/")
            if norm.hasPrefix(".trellis/") { return false }
            return !covered.contains(norm)
        }
    }

    /// Active task directory absolute path on disk.
    public var selectedTaskDirectoryPath: String? {
        selectedTask?.taskDirectoryPath
    }

    // MARK: Presentation & Preference Controls

    public func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        onExpansionChanged?(true)
    }

    public func collapse() {
        guard isExpanded || isSettingsOpen else { return }
        isSettingsOpen = false
        isExpanded = false
        onExpansionChanged?(false)
    }

    public func toggleExpanded() {
        if isExpanded { collapse() } else { expand() }
    }

    public func toggleSettings() {
        isSettingsOpen.toggle()
        if isSettingsOpen {
            refreshHookStatuses()
        }
    }

    public func setPresentationMode(_ mode: PresentationMode) {
        guard config.presentationMode != mode else { return }
        config.presentationMode = mode
        persistConfig()
        onPresentationModeChanged?(mode)
        showToast(l10n.t(
            mode == .notch ? "Switched to Notch HUD" : "Switched to Edge Pill",
            mode == .notch ? "已切换至刘海 HUD" : "已切换至吸边胶囊"
        ))
    }

    public func togglePresentationMode() {
        setPresentationMode(presentationMode == .notch ? .edgePill : .notch)
    }

    public func setEdgeAnchor(_ anchor: EdgeAnchor) {
        guard config.edgeAnchor != anchor else { return }
        config.edgeAnchor = anchor
        persistConfig()
        onEdgeAnchorChanged?(anchor)
    }

    public func setEdgeVerticalRatio(_ ratio: Double) {
        let clamped = min(max(ratio, 0.08), 0.92)
        guard abs(config.edgeVerticalRatio - clamped) > 0.002 else { return }
        config.edgeVerticalRatio = clamped
        persistConfig()
    }

    public func setShowMenuBarIcon(_ visible: Bool) {
        guard showMenuBarIcon != visible else { return }
        showMenuBarIcon = visible
        UserDefaults.standard.set(visible, forKey: Self.showMenuBarIconDefaultsKey)
        onMenuBarVisibilityChanged?(visible)
    }

    public func setAutoFollowFocus(_ enabled: Bool) {
        guard config.autoFollowFocus != enabled else { return }
        config.autoFollowFocus = enabled
        persistConfig()
    }

    public func setLanguage(_ newLanguage: AppLanguage) {
        guard config.language != newLanguage else { return }
        config.language = newLanguage
        persistConfig()
        onLanguageChanged?(l10n)
    }

    /// Persists the user-resized expanded Workbench window dimensions without triggering frame animations.
    public func setWorkbenchSize(_ size: CGSize) {
        let clamped = CGSize(
            width: max(640, size.width.rounded()),
            height: max(420, size.height.rounded())
        )
        guard abs(workbenchSize.width - clamped.width) >= 1 || abs(workbenchSize.height - clamped.height) >= 1 else {
            return
        }
        workbenchSize = clamped
        UserDefaults.standard.set(Double(clamped.width), forKey: Self.workbenchWidthDefaultsKey)
        UserDefaults.standard.set(Double(clamped.height), forKey: Self.workbenchHeightDefaultsKey)
    }

    // MARK: Selection & Cross-Tab Navigation

    public func selectProject(_ path: String?) {
        guard selectedProjectPath != path else { return }
        selectedProjectPath = path
        config.selectedProjectPath = path
        persistConfig()
        selectedTaskId = nil
        selectedDocPath = nil
        selectedDocContent = ""
        lastLoadedDocTaskDir = nil
        selectedSpecPath = nil
        historyDirty = true
        historyLoadedForProject = nil
        refreshSelectedProjectDetails()
    }

    public func selectTask(_ id: String?) {
        guard selectedTaskId != id else { return }
        selectedTaskId = id
        selectedDocPath = nil
        selectedDocContent = ""
        lastLoadedDocTaskDir = nil
        if let firstDoc = selectedTask?.artifacts.documentPaths.first {
            loadDocument(firstDoc)
        }
    }

    public func selectChannel(_ id: String?) {
        guard selectedChannelId != id else { return }
        selectedChannelId = id
    }

    public func selectSpec(_ relativePath: String?) {
        guard selectedSpecPath != relativePath else { return }
        selectedSpecPath = relativePath
    }

    public func openSpecInDocsTab(_ specPath: String) {
        if let match = specs.first(where: { $0.relativePath == specPath || $0.absolutePath == specPath }) {
            selectedSpecPath = match.relativePath
        } else {
            selectedSpecPath = specPath
        }
        docsSubMode = .projectSpecs
        selectedTab = .docsSpecs
    }

    /// Routes Markdown links safely in-app so schemeless relative URLs NEVER leak to macOS Finder (`-50` paramErr).
    /// Returns `true` when handled internally (or gracefully suppressed with toast), `false` when SwiftUI should delegate
    /// to the system browser (`http`, `https`, `mailto`).
    public func handleMarkdownLink(
        _ url: URL,
        baseFilePath: String?,
        currentTask: TaskSnapshot? = nil,
        onSelectTaskDoc: ((String) -> Void)? = nil
    ) -> Bool {
        if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            return false
        }

        let rawString = url.absoluteString
        if rawString.hasPrefix("#") {
            return true
        }

        // Extract raw filesystem/relative path without fragment or query
        let rawPath: String
        if url.isFileURL {
            rawPath = url.path
        } else {
            let candidate = url.relativeString.isEmpty ? rawString : url.relativeString
            let withoutFragment = candidate.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? candidate
            let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? withoutFragment
            rawPath = (withoutQuery.removingPercentEncoding ?? withoutQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !rawPath.isEmpty else {
            return true
        }

        // Build candidate normalized absolute paths
        var candidates: [String] = []
        func appendCandidate(_ path: String) {
            let norm = ConfigStore.normalizePath(path)
            if !norm.isEmpty && !candidates.contains(norm) {
                candidates.append(norm)
            }
        }

        if rawPath.hasPrefix("/") || rawPath.hasPrefix("~") {
            appendCandidate(rawPath)
        } else {
            if let baseFilePath, !baseFilePath.isEmpty {
                let baseDir = URL(fileURLWithPath: ConfigStore.normalizePath(baseFilePath)).deletingLastPathComponent()
                appendCandidate(baseDir.appendingPathComponent(rawPath).path)
            }
            if let taskDir = currentTask?.taskDirectoryPath, !taskDir.isEmpty {
                appendCandidate(URL(fileURLWithPath: taskDir).appendingPathComponent(rawPath).path)
            }
            if let projectPath = selectedProjectPath, !projectPath.isEmpty {
                appendCandidate(URL(fileURLWithPath: projectPath).appendingPathComponent(rawPath).path)
            }
        }

        // 1. Check if any candidate matches a known Project Spec
        for candidate in candidates {
            if let spec = specs.first(where: { ConfigStore.normalizePath($0.absolutePath) == candidate }) {
                openSpecInDocsTab(spec.relativePath)
                return true
            }
        }

        // 2. Check if any candidate lies inside the current task directory
        if let task = currentTask {
            let normalizedTaskDir = ConfigStore.normalizePath(task.taskDirectoryPath)
            let prefix = normalizedTaskDir.hasSuffix("/") ? normalizedTaskDir : normalizedTaskDir + "/"
            for candidate in candidates where candidate.hasPrefix(prefix) {
                if FileManager.default.fileExists(atPath: candidate) {
                    let relPath = String(candidate.dropFirst(prefix.count))
                    if let onSelectTaskDoc {
                        onSelectTaskDoc(relPath)
                    } else if task.id == selectedTask?.id {
                        loadDocument(relPath)
                    } else {
                        openInEditor(path: candidate)
                    }
                    return true
                }
            }
        }

        // 3. Open existing local file cleanly via URL(fileURLWithPath:)
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                openInEditor(path: candidate)
                return true
            }
        }

        // 4. Missing target: show localized toast and return true so Finder never receives a bad URL
        let displayName = URL(fileURLWithPath: rawPath).lastPathComponent
        let label = displayName.isEmpty ? rawPath : displayName
        showToast(l10n.t("Link target not found: \(label)", "未找到链接目标：\(label)"), isError: true)
        return true
    }

    // MARK: Refresh Pipeline (Equality-Guarded, Zero Double-Scan, Lazy History)

    public func refreshAll() {
        refreshTask?.cancel()
        if !isRefreshing { isRefreshing = true }
        let currentProvider = provider
        let roots = config.roots
        let dynamicProjects = config.dynamicProjects
        let preferredProjectPath = selectedProjectPath
        let shouldLoadHistory = (selectedTab == .history)
        let query = historyQuery

        refreshTask = Task { [weak self] in
            let discovered = await Task.detached(priority: .userInitiated) {
                currentProvider.discoverProjects(roots, dynamicProjects)
            }.value
            guard !Task.isCancelled, let self else { return }

            if self.projects != discovered {
                self.projects = discovered
            }
            let nextProjectPath: String?
            if let preferred = preferredProjectPath, discovered.contains(where: { $0.path == preferred }) {
                nextProjectPath = preferred
            } else {
                nextProjectPath = discovered.first?.path
            }
            if self.selectedProjectPath != nextProjectPath {
                self.selectedProjectPath = nextProjectPath
            }

            let watchedPaths = discovered.map { "\($0.path)/.trellis" }
            self.onWatchedPathsChanged?(watchedPaths)

            let targetProject = self.selectedProjectPath
            let result = await Task.detached(priority: .userInitiated) {
                let active = targetProject.map { currentProvider.scanActiveTasks($0) } ?? []
                let specRefs = active.flatMap(\.artifacts.specRefs)
                let specsAndGit = targetProject.map { currentProvider.scanSpecsAndGit($0, specRefs) } ?? ([], nil)
                let channels = currentProvider.scanChannels()
                let archived = shouldLoadHistory ? (targetProject.map { currentProvider.scanArchivedTasks($0) } ?? []) : nil
                let journals = shouldLoadHistory ? (targetProject.map { currentProvider.scanJournals($0) } ?? []) : nil
                let memory = shouldLoadHistory ? currentProvider.searchMemory(query, targetProject) : nil
                return (active, specsAndGit.0, specsAndGit.1, channels, archived, journals, memory)
            }.value
            guard !Task.isCancelled else { return }

            if self.activeTasks != result.0 { self.activeTasks = result.0 }
            if self.specs != result.1 { self.specs = result.1 }
            if self.gitStatus != result.2 { self.gitStatus = result.2 }
            if self.channels != result.3 { self.channels = result.3 }

            if let archived = result.4, let journals = result.5, let memory = result.6 {
                if self.archivedTasks != archived { self.archivedTasks = archived }
                if self.journals != journals { self.journals = journals }
                if self.memorySessions != memory { self.memorySessions = memory }
                self.historyLoadedForProject = targetProject
                self.historyDirty = false
            } else {
                self.historyDirty = true
            }

            if self.selectedTaskId == nil || !self.activeTasks.contains(where: { $0.id == self.selectedTaskId }) {
                self.selectedTaskId = self.activeTasks.first?.id
            }
            if self.selectedSpecPath == nil || !self.specs.contains(where: { $0.relativePath == self.selectedSpecPath }) {
                self.selectedSpecPath = self.specs.first?.relativePath
            }
            if self.selectedChannelId == nil || !self.channels.contains(where: { $0.id == self.selectedChannelId }) {
                self.selectedChannelId = self.channels.first?.id
            }

            if let docPath = self.selectedDocPath ?? self.selectedTask?.artifacts.documentPaths.first {
                self.loadDocument(docPath, silentIfSamePath: true)
            } else {
                if self.selectedDocPath != nil { self.selectedDocPath = nil }
                if !self.selectedDocContent.isEmpty { self.selectedDocContent = "" }
                self.lastLoadedDocTaskDir = nil
            }

            if self.isRefreshing { self.isRefreshing = false }
        }
    }

    public func refreshSelectedProjectDetails() {
        projectDetailTask?.cancel()
        let currentProvider = provider
        let targetProject = selectedProjectPath
        let shouldLoadHistory = (selectedTab == .history)
        let query = historyQuery

        projectDetailTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let active = targetProject.map { currentProvider.scanActiveTasks($0) } ?? []
                let specRefs = active.flatMap(\.artifacts.specRefs)
                let specsAndGit = targetProject.map { currentProvider.scanSpecsAndGit($0, specRefs) } ?? ([], nil)
                let archived = shouldLoadHistory ? (targetProject.map { currentProvider.scanArchivedTasks($0) } ?? []) : nil
                let journals = shouldLoadHistory ? (targetProject.map { currentProvider.scanJournals($0) } ?? []) : nil
                let memory = shouldLoadHistory ? currentProvider.searchMemory(query, targetProject) : nil
                return (active, specsAndGit.0, specsAndGit.1, archived, journals, memory)
            }.value
            guard !Task.isCancelled, let self else { return }

            if self.activeTasks != result.0 { self.activeTasks = result.0 }
            if self.specs != result.1 { self.specs = result.1 }
            if self.gitStatus != result.2 { self.gitStatus = result.2 }
            if let archived = result.3, let journals = result.4, let memory = result.5 {
                if self.archivedTasks != archived { self.archivedTasks = archived }
                if self.journals != journals { self.journals = journals }
                if self.memorySessions != memory { self.memorySessions = memory }
                self.historyLoadedForProject = targetProject
                self.historyDirty = false
            } else {
                self.historyDirty = true
            }

            self.selectedTaskId = self.activeTasks.first?.id
            self.selectedSpecPath = self.specs.first?.relativePath
            if let doc = self.selectedTask?.artifacts.documentPaths.first {
                self.loadDocument(doc)
            }
        }
    }

    public func refreshHistoryIfNeeded() {
        guard historyDirty || historyLoadedForProject != selectedProjectPath else { return }
        refreshHistory()
    }

    public func refreshHistory() {
        historyTask?.cancel()
        isLoadingHistory = true
        let currentProvider = provider
        let targetProject = selectedProjectPath
        let query = historyQuery

        historyTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let archived = targetProject.map { currentProvider.scanArchivedTasks($0) } ?? []
                let journals = targetProject.map { currentProvider.scanJournals($0) } ?? []
                let memory = currentProvider.searchMemory(query, targetProject)
                return (archived, journals, memory)
            }.value
            guard !Task.isCancelled, let self else { return }

            if self.archivedTasks != result.0 { self.archivedTasks = result.0 }
            if self.journals != result.1 { self.journals = result.1 }
            if self.memorySessions != result.2 { self.memorySessions = result.2 }
            self.historyLoadedForProject = targetProject
            self.historyDirty = false
            self.isLoadingHistory = false
        }
    }

    public func refreshChannelsOnly() {
        let currentProvider = provider
        Task { [weak self] in
            let latest = await Task.detached(priority: .utility) {
                currentProvider.scanChannels()
            }.value
            guard let self else { return }
            if self.channels != latest {
                self.channels = latest
            }
            if self.selectedChannelId == nil || !latest.contains(where: { $0.id == self.selectedChannelId }) {
                self.selectedChannelId = latest.first?.id
            }
        }
    }

    // MARK: Documents & History Search

    public func loadDocument(_ relativePath: String, silentIfSamePath: Bool = false) {
        let sameDoc = (selectedDocPath == relativePath && lastLoadedDocTaskDir == selectedTaskDirectoryPath)
        if selectedDocPath != relativePath {
            selectedDocPath = relativePath
        }
        guard let taskDir = selectedTaskDirectoryPath else {
            if !selectedDocContent.isEmpty { selectedDocContent = "" }
            lastLoadedDocTaskDir = nil
            return
        }
        if !silentIfSamePath || !sameDoc {
            isLoadingDoc = true
        }
        let currentProvider = provider
        Task { [weak self] in
            let content = await Task.detached(priority: .userInitiated) {
                currentProvider.loadDocument(taskDir, relativePath)
            }.value
            guard let self, self.selectedDocPath == relativePath, self.selectedTaskDirectoryPath == taskDir else {
                return
            }
            let text = content ?? ""
            if self.selectedDocContent != text {
                self.selectedDocContent = text
            }
            self.lastLoadedDocTaskDir = taskDir
            if self.isLoadingDoc {
                self.isLoadingDoc = false
            }
        }
    }

    /// Loads any markdown document (`prd.md`, `design.md`, `implement.md`, `research/*.md`) for either an active or archived task.
    public func loadDocument(for task: TaskSnapshot, relativePath: String) async -> String {
        let currentProvider = provider
        let taskDir = task.taskDirectoryPath
        let content = await Task.detached(priority: .userInitiated) {
            currentProvider.loadDocument(taskDir, relativePath)
        }.value
        return content ?? ""
    }

    public func reloadCurrentDocument() {
        guard let docPath = selectedDocPath else { return }
        loadDocument(docPath, silentIfSamePath: false)
    }

    public func openDocumentInEditor(_ relativePath: String) {
        guard let taskDir = selectedTaskDirectoryPath else { return }
        let fullPath = URL(fileURLWithPath: taskDir).appendingPathComponent(relativePath).path
        openInEditor(path: fullPath)
    }

    public func openDocumentInEditor(for task: TaskSnapshot, relativePath: String) {
        let fullPath = URL(fileURLWithPath: task.taskDirectoryPath).appendingPathComponent(relativePath).path
        openInEditor(path: fullPath)
    }

    public func openSpecInEditor(_ spec: SpecDocument) {
        openInEditor(path: spec.absolutePath)
    }

    public func openInEditor(path: String) {
        let url = URL(fileURLWithPath: path)
        if !NSWorkspace.shared.open(url) {
            showToast(l10n.t("Could not open \(url.lastPathComponent)", "无法打开 \(url.lastPathComponent)"), isError: true)
        }
    }

    public func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func searchHistory(_ query: String) {
        historyQuery = query
        searchTask?.cancel()
        let currentProvider = provider
        let projectPath = selectedProjectPath
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                currentProvider.searchMemory(query, projectPath)
            }.value
            guard !Task.isCancelled, let self else { return }
            if self.memorySessions != results {
                self.memorySessions = results
            }
        }
    }

    // MARK: Human-Gate Actions

    public func jumpToTerminal(agent: AgentKind? = nil) {
        let preferredAgent = agent ?? activeSessions.first?.agent
        let projectPath = selectedProjectPath ?? activeSessions.first?.projectPath
        onJumpToTerminal?(preferredAgent, projectPath)
    }

    public func jumpToSession(_ session: AgentSessionState) {
        if let match = projects.first(where: { $0.path == session.projectPath }) {
            selectProject(match.path)
        }
        onJumpToTerminal?(session.agent, session.projectPath)
    }

    public func runValidate() {
        runAction(.validate)
    }

    public func runStartTask() {
        runAction(.start)
    }

    public func runArchiveTask() {
        runAction(.archive)
    }

    private func runAction(_ action: ActionKind) {
        guard runningAction == nil else { return }
        guard let task = selectedTask else {
            showToast(l10n.t("Select an active task first", "请先选择一个活跃任务"), isError: true)
            return
        }
        runningAction = action
        let currentProvider = provider
        let projectPath = task.projectPath
        let taskDir = task.dir

        Task { [weak self] in
            let result = await currentProvider.runTaskAction(action, projectPath, taskDir)
            guard let self else { return }
            self.runningAction = nil
            self.lastActionResult = result
            if result.success {
                let verb: String = switch action {
                case .validate: self.l10n.t("Validation passed", "校验通过")
                case .start: self.l10n.t("Task started", "任务已启动")
                case .archive: self.l10n.t("Task archived", "任务已归档")
                default: self.l10n.t("Action succeeded", "操作成功")
                }
                self.showToast(result.message.isEmpty ? verb : result.message)
                self.historyDirty = true
                self.refreshAll()
            } else {
                let detail = result.message.isEmpty ? result.stderr : result.message
                let firstLine = detail.split(whereSeparator: \.isNewline).first.map(String.init)
                    ?? self.l10n.t("Action failed", "操作失败")
                self.showToast(firstLine, isError: true)
            }
        }
    }

    // MARK: Hook Event Ingestion (from HUDUnixSocketServer / Inbox)

    public func ingestHookEvent(_ event: HookEvent) {
        let rawProject = event.project
        let alreadyKnown = projects.contains(where: { $0.path == rawProject })
            || config.dynamicProjects.contains(rawProject)

        let normalizedProject = alreadyKnown ? rawProject : ConfigStore.normalizePath(rawProject)
        var normalizedEvent = event
        normalizedEvent.project = normalizedProject

        // Short-circuit in memory before touching FileManager
        if !alreadyKnown,
           !projects.contains(where: { $0.path == normalizedProject }),
           !config.dynamicProjects.contains(normalizedProject),
           !normalizedProject.isEmpty {
            let trellisTasksPath = URL(fileURLWithPath: normalizedProject).appendingPathComponent(".trellis/tasks").path
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: trellisTasksPath, isDirectory: &isDir), isDir.boolValue {
                config.dynamicProjects.append(normalizedProject)
                persistConfig()
                refreshAll()
            }
        }

        let applied = sessionRegistry.apply(normalizedEvent)
        guard applied else { return }

        rebuildSessionSnapshot()

        // Emit macOS notification when entering an attention-required state
        if let session = activeSessions.first(where: { $0.sessionId == normalizedEvent.sessionId }),
           session.status.isAttentionRequired {
            let eventDate = session.updatedAt
            let lastAlert = alertedSessionTimestamps[session.sessionId]
            if lastAlert == nil || eventDate.timeIntervalSince(lastAlert!) > 5 {
                alertedSessionTimestamps[session.sessionId] = eventDate
                onAttentionAlert?(session)
            }
        }

        // Auto-follow focus when enabled
        if config.autoFollowFocus, !normalizedProject.isEmpty {
            if selectedProjectPath != normalizedProject, projects.contains(where: { $0.path == normalizedProject }) {
                selectedProjectPath = normalizedProject
                refreshSelectedProjectDetails()
            }
            if let taskId = normalizedEvent.taskId,
               let match = activeTasks.first(where: { $0.dir == taskId || $0.record.id == taskId }),
               selectedTaskId != match.id {
                selectedTaskId = match.id
            }
        }
    }

    @discardableResult
    public func pruneStaleSessions(now: Date = Date()) -> Bool {
        let before = sessionRegistry.allSessionsSorted()
        sessionRegistry.prune(now: now)
        let after = sessionRegistry.allSessionsSorted()
        guard before != after else { return false }
        rebuildSessionSnapshot()
        return true
    }

    private func rebuildSessionSnapshot() {
        let snapshot = FocusEngine.buildFocusSnapshot(
            tasks: activeTasks,
            registry: sessionRegistry,
            previousFocusKey: selectedTaskId
        )
        let nextActivities = Array(snapshot.recentActivities.prefix(Self.maxActivityHistory))
        if activeSessions != snapshot.activeSessions {
            activeSessions = snapshot.activeSessions
        }
        if recentActivities != nextActivities {
            recentActivities = nextActivities
        }
        if focusSnapshot.focusedTaskKey != snapshot.focusedTaskKey
            || focusSnapshot.focusedProjectPath != snapshot.focusedProjectPath
            || focusSnapshot.focusedSessionId != snapshot.focusedSessionId
            || focusSnapshot.status != snapshot.status
            || focusSnapshot.attentionCount != snapshot.attentionCount
            || focusSnapshot.activeSessions != snapshot.activeSessions
            || focusSnapshot.recentActivities != snapshot.recentActivities {
            focusSnapshot = snapshot
        }
    }

    // MARK: Watched Roots & Hook Configuration (Settings)

    public func addRootFolderInteractive() {
        onModalPresentationChanged?(true)
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = l10n.t("Watch Folder", "添加监听目录")
        panel.message = l10n.t(
            "Select a project or workspace folder containing .trellis projects.",
            "选择包含 .trellis 项目的工程或工作区目录。"
        )
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.onModalPresentationChanged?(false)
                if response == .OK, let url = panel.url {
                    self.addRootFolder(url.path)
                }
            }
        }
    }

    public func addRootFolder(_ path: String) {
        let expanded = ConfigStore.expandHome(path)
        guard !config.roots.contains(expanded) else {
            showToast(l10n.t("Folder already watched", "该目录已在监听列表中"))
            return
        }
        config.roots.append(expanded)
        config.initialized = true
        persistConfig()
        showToast(l10n.t(
            "Added \(URL(fileURLWithPath: expanded).lastPathComponent)",
            "已添加 \(URL(fileURLWithPath: expanded).lastPathComponent)"
        ))
        refreshAll()
    }

    public func removeRootFolder(_ path: String) {
        config.roots.removeAll { $0 == path }
        persistConfig()
        showToast(l10n.t("Removed watched folder", "已移除监听目录"))
        refreshAll()
    }

    public func rediscoverProjects() {
        historyDirty = true
        refreshAll()
        showToast(l10n.t("Scanning watched folders…", "正在重新扫描目录…"))
    }

    public func refreshHookStatuses() {
        let currentProvider = provider
        Task { [weak self] in
            let latest = await Task.detached(priority: .utility) {
                currentProvider.getHookStatuses()
            }.value
            guard let self else { return }
            if self.hookStatuses != latest {
                self.hookStatuses = latest
            }
        }
    }

    public func setHookEnabled(_ enabled: Bool, for agent: AgentKind) {
        guard updatingHookAgent == nil else { return }
        updatingHookAgent = agent
        let currentProvider = provider
        Task { [weak self] in
            let outcome: Result<AgentHookStatusInfo, Error> = await Task.detached(priority: .userInitiated) {
                Result { try currentProvider.configureHook(agent, enabled) }
            }.value
            guard let self else { return }
            self.updatingHookAgent = nil
            switch outcome {
            case .success(let updated):
                if let idx = self.hookStatuses.firstIndex(where: { $0.agent == agent }) {
                    self.hookStatuses[idx] = updated
                } else {
                    self.hookStatuses.append(updated)
                }
                self.showToast(self.l10n.t(
                    "\(agent.displayName) hook \(enabled ? "installed" : "removed")",
                    "\(agent.displayName) Hook 已\(enabled ? "安装" : "卸载")"
                ))
            case .failure(let error):
                self.showToast("\(agent.displayName): \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: Toast Helpers

    public func showToast(_ message: String, isError: Bool = false) {
        toastDismissTask?.cancel()
        let toast = StatusToast(message: message, isError: isError)
        statusToast = toast
        let duration: Duration = isError ? .seconds(4.5) : .seconds(2.2)
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.statusToast?.id == toast.id else { return }
            self.statusToast = nil
        }
    }

    public func dismissToast() {
        toastDismissTask?.cancel()
        statusToast = nil
    }

    // MARK: Config Persistence

    private func persistConfig() {
        do {
            try provider.saveConfig(config)
        } catch {
            showToast(l10n.t(
                "Failed to save config: \(error.localizedDescription)",
                "保存配置失败：\(error.localizedDescription)"
            ), isError: true)
        }
    }
}
