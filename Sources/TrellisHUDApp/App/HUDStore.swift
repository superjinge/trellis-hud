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
        switch self {
        case .flow: return "Flow"
        case .live: return "Live"
        case .docsSpecs: return "Docs & Specs"
        case .history: return "History"
        }
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
    public var scanSpecsAndGit: @Sendable (String) -> ([SpecDocument], GitStatusSnapshot?)
    public var scanChannels: @Sendable () -> [ChannelInfo]
    public var scanJournals: @Sendable (String) -> [WorkspaceJournal]
    public var searchMemory: @Sendable (String, String?) -> [MemorySessionItem]
    public var runTaskAction: @Sendable (ActionKind, String, String) async -> ActionResult
    public var getHookStatuses: @Sendable () -> [AgentHookStatusInfo]
    public var configureHook: @Sendable (AgentKind, Bool) throws -> AgentHookStatusInfo

    public init(
        loadConfig: @escaping @Sendable () -> HUDConfig = { HUDStore.loadConfigFallback() },
        saveConfig: @escaping @Sendable (HUDConfig) throws -> Void = { try HUDStore.saveConfigFallback($0) },
        discoverProjects: @escaping @Sendable ([String], [String]) -> [ProjectInfo] = { _, _ in [] },
        scanActiveTasks: @escaping @Sendable (String) -> [TaskSnapshot] = { _ in [] },
        scanArchivedTasks: @escaping @Sendable (String) -> [TaskSnapshot] = { _ in [] },
        loadDocument: @escaping @Sendable (String, String) -> String? = { HUDStore.loadDocumentFallback(taskDir: $0, relativePath: $1) },
        scanSpecsAndGit: @escaping @Sendable (String) -> ([SpecDocument], GitStatusSnapshot?) = { _ in ([], nil) },
        scanChannels: @escaping @Sendable () -> [ChannelInfo] = { [] },
        scanJournals: @escaping @Sendable (String) -> [WorkspaceJournal] = { _ in [] },
        searchMemory: @escaping @Sendable (String, String?) -> [MemorySessionItem] = { _, _ in [] },
        runTaskAction: @escaping @Sendable (ActionKind, String, String) async -> ActionResult = { action, _, _ in
            ActionResult(success: false, action: action, exitCode: 1, message: "Action runner not connected yet")
        },
        getHookStatuses: @escaping @Sendable () -> [AgentHookStatusInfo] = { HUDStore.defaultHookStatuses() },
        configureHook: @escaping @Sendable (AgentKind, Bool) throws -> AgentHookStatusInfo = { agent, enabled in
            AgentHookStatusInfo(
                agent: agent,
                installed: enabled,
                configExists: false,
                configPath: "",
                isSupported: agent != .antigravity,
                detail: "Hook installer wiring pending"
            )
        }
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
            scanSpecsAndGit: { projectPath in
                let tasks = ProjectScanner.scanActiveTasks(projectPath: projectPath)
                let refs = tasks.flatMap(\.artifacts.specRefs)
                let report = SpecAndGitAnalyzer.analyzeGovernance(
                    projectPath: projectPath,
                    referencedSpecPaths: refs
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
                        detail: st.agent == .antigravity ? "Hooks + automatic trellis mem" : nil
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
                    detail: st.agent == .antigravity ? "Hooks + automatic trellis mem" : nil
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
    public var showMenuBarIcon: Bool

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
    public var onWatchedPathsChanged: (([String]) -> Void)?
    public var onAttentionAlert: ((AgentSessionState) -> Void)?
    public var onJumpToTerminal: ((AgentKind?, String?) -> Void)?

    // MARK: Internal State

    private var provider: HUDDataProvider
    private var toastDismissTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var sessionRegistry: SessionRegistry = SessionRegistry()
    private var alertedSessionTimestamps: [String: Date] = [:]

    private static let showMenuBarIconDefaultsKey = "trellisHUD.showMenuBarIcon"
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
        self.hookStatuses = provider.getHookStatuses()
    }

    public func updateProvider(_ newProvider: HUDDataProvider) {
        self.provider = newProvider
        self.hookStatuses = newProvider.getHookStatuses()
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
        if let alert = attentionSessions.first {
            return alert.status.label
        }
        guard let task = selectedTask else {
            return activeAgentCount > 0 ? "Working" : "Idle"
        }
        let shortPhase: String = {
            switch task.phase {
            case .explore: return "Explore"
            case .plan: return "Plan"
            case .implement: return "Impl"
            case .check: return "Check"
            case .archive: return "Archive"
            }
        }()
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

    public var ambientSubtitle: String {
        if let top = activeSessions.first {
            if let activity = top.activity, !activity.isEmpty {
                return activity
            }
            if let tool = top.toolName, !tool.isEmpty {
                return "\(top.agent.displayName) · \(tool)"
            }
            return "\(top.agent.displayName) · \(top.status.label)"
        }
        if let task = selectedTask, let warning = task.phaseWarning, !warning.isEmpty {
            return warning
        }
        return selectedProject?.name ?? "No watched project"
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
        guard let task = selectedTask else { return nil }
        return URL(fileURLWithPath: task.projectPath)
            .appendingPathComponent(".trellis/tasks", isDirectory: true)
            .appendingPathComponent(task.dir, isDirectory: true)
            .path
    }

    // MARK: Presentation Controls

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
    }

    public func setPresentationMode(_ mode: PresentationMode) {
        guard config.presentationMode != mode else { return }
        config.presentationMode = mode
        persistConfig()
        onPresentationModeChanged?(mode)
        showToast(mode == .notch ? "Switched to Notch HUD" : "Switched to Edge Pill")
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
        config.autoFollowFocus = enabled
        persistConfig()
    }

    // MARK: Selection & Navigation

    public func selectProject(_ path: String?) {
        selectedProjectPath = path
        config.selectedProjectPath = path
        persistConfig()
        selectedTaskId = nil
        selectedDocPath = nil
        selectedDocContent = ""
        selectedSpecPath = nil
        refreshSelectedProjectDetails()
    }

    public func selectTask(_ id: String?) {
        selectedTaskId = id
        selectedDocPath = nil
        selectedDocContent = ""
        if let firstDoc = selectedTask?.artifacts.documentPaths.first {
            loadDocument(firstDoc)
        }
    }

    public func selectChannel(_ id: String?) {
        selectedChannelId = id
    }

    public func selectSpec(_ relativePath: String?) {
        selectedSpecPath = relativePath
    }

    // MARK: Refresh Pipeline

    public func refreshAll() {
        refreshTask?.cancel()
        isRefreshing = true
        let currentProvider = provider
        let roots = config.roots
        let dynamicProjects = config.dynamicProjects
        let preferredProjectPath = selectedProjectPath
        let query = historyQuery

        refreshTask = Task { [weak self] in
            let discovered = await Task.detached(priority: .userInitiated) {
                currentProvider.discoverProjects(roots, dynamicProjects)
            }.value
            guard !Task.isCancelled, let self else { return }

            self.projects = discovered
            if let preferred = preferredProjectPath, discovered.contains(where: { $0.path == preferred }) {
                self.selectedProjectPath = preferred
            } else {
                self.selectedProjectPath = discovered.first?.path
            }

            let watchedPaths = discovered.map { "\($0.path)/.trellis" }
            self.onWatchedPathsChanged?(watchedPaths)

            let targetProject = self.selectedProjectPath
            let result = await Task.detached(priority: .userInitiated) {
                let active = targetProject.map { currentProvider.scanActiveTasks($0) } ?? []
                let archived = targetProject.map { currentProvider.scanArchivedTasks($0) } ?? []
                let specsAndGit = targetProject.map { currentProvider.scanSpecsAndGit($0) } ?? ([], nil)
                let channels = currentProvider.scanChannels()
                let journals = targetProject.map { currentProvider.scanJournals($0) } ?? []
                let memory = currentProvider.searchMemory(query, targetProject)
                return (active, archived, specsAndGit.0, specsAndGit.1, channels, journals, memory)
            }.value
            guard !Task.isCancelled else { return }

            self.activeTasks = result.0
            self.archivedTasks = result.1
            self.specs = result.2
            self.gitStatus = result.3
            self.channels = result.4
            self.journals = result.5
            self.memorySessions = result.6

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
                self.loadDocument(docPath)
            } else {
                self.selectedDocPath = nil
                self.selectedDocContent = ""
            }

            self.isRefreshing = false
        }
    }

    public func refreshSelectedProjectDetails() {
        let currentProvider = provider
        let targetProject = selectedProjectPath
        let query = historyQuery

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let active = targetProject.map { currentProvider.scanActiveTasks($0) } ?? []
                let archived = targetProject.map { currentProvider.scanArchivedTasks($0) } ?? []
                let specsAndGit = targetProject.map { currentProvider.scanSpecsAndGit($0) } ?? ([], nil)
                let journals = targetProject.map { currentProvider.scanJournals($0) } ?? []
                let memory = currentProvider.searchMemory(query, targetProject)
                return (active, archived, specsAndGit.0, specsAndGit.1, journals, memory)
            }.value
            guard let self else { return }

            self.activeTasks = result.0
            self.archivedTasks = result.1
            self.specs = result.2
            self.gitStatus = result.3
            self.journals = result.4
            self.memorySessions = result.5
            self.selectedTaskId = self.activeTasks.first?.id
            self.selectedSpecPath = self.specs.first?.relativePath
            if let doc = self.selectedTask?.artifacts.documentPaths.first {
                self.loadDocument(doc)
            }
        }
    }

    public func refreshChannelsOnly() {
        let currentProvider = provider
        Task { [weak self] in
            let latest = await Task.detached(priority: .utility) {
                currentProvider.scanChannels()
            }.value
            guard let self else { return }
            self.channels = latest
            if self.selectedChannelId == nil || !latest.contains(where: { $0.id == self.selectedChannelId }) {
                self.selectedChannelId = latest.first?.id
            }
        }
    }

    // MARK: Documents & History Search

    public func loadDocument(_ relativePath: String) {
        selectedDocPath = relativePath
        guard let taskDir = selectedTaskDirectoryPath else {
            selectedDocContent = ""
            return
        }
        isLoadingDoc = true
        let currentProvider = provider
        Task { [weak self] in
            let content = await Task.detached(priority: .userInitiated) {
                currentProvider.loadDocument(taskDir, relativePath)
            }.value
            guard let self, self.selectedDocPath == relativePath else { return }
            self.selectedDocContent = content ?? ""
            self.isLoadingDoc = false
        }
    }

    public func reloadCurrentDocument() {
        guard let docPath = selectedDocPath else { return }
        loadDocument(docPath)
    }

    public func openDocumentInEditor(_ relativePath: String) {
        guard let taskDir = selectedTaskDirectoryPath else { return }
        let fullPath = URL(fileURLWithPath: taskDir).appendingPathComponent(relativePath).path
        openInEditor(path: fullPath)
    }

    public func openSpecInEditor(_ spec: SpecDocument) {
        openInEditor(path: spec.absolutePath)
    }

    public func openInEditor(path: String) {
        let url = URL(fileURLWithPath: path)
        if !NSWorkspace.shared.open(url) {
            showToast("Could not open \(url.lastPathComponent)", isError: true)
        }
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
            self.memorySessions = results
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
            showToast("Select an active task first", isError: true)
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
                case .validate: "Validation passed"
                case .start: "Task started"
                case .archive: "Task archived"
                default: "Action succeeded"
                }
                self.showToast(result.message.isEmpty ? verb : result.message)
                self.refreshAll()
            } else {
                let detail = result.message.isEmpty ? result.stderr : result.message
                let firstLine = detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Action failed"
                self.showToast(firstLine, isError: true)
            }
        }
    }

    // MARK: Hook Event Ingestion (from HUDUnixSocketServer / Inbox)

    public func ingestHookEvent(_ event: HookEvent) {
        let normalizedProject = ConfigStore.normalizePath(event.project)
        var normalizedEvent = event
        normalizedEvent.project = normalizedProject

        // Register dynamic project if it looks like a valid Trellis project
        let trellisTasksPath = URL(fileURLWithPath: normalizedProject).appendingPathComponent(".trellis/tasks").path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: trellisTasksPath, isDirectory: &isDir), isDir.boolValue {
            if !config.dynamicProjects.contains(normalizedProject) && !projects.contains(where: { $0.path == normalizedProject }) {
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
               let match = activeTasks.first(where: { $0.dir == taskId || $0.record.id == taskId }) {
                selectedTaskId = match.id
            }
        }
    }

    public func pruneStaleSessions(now: Date = Date()) {
        sessionRegistry.prune(now: now)
        rebuildSessionSnapshot()
    }

    private func rebuildSessionSnapshot() {
        let snapshot = FocusEngine.buildFocusSnapshot(
            tasks: activeTasks,
            registry: sessionRegistry,
            previousFocusKey: selectedTaskId
        )
        focusSnapshot = snapshot
        activeSessions = snapshot.activeSessions
        recentActivities = Array(snapshot.recentActivities.prefix(Self.maxActivityHistory))
    }

    // MARK: Watched Roots & Hook Configuration (Settings)

    public func addRootFolderInteractive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch Folder"
        panel.message = "Select a project or workspace folder containing .trellis projects."
        if panel.runModal() == .OK, let url = panel.url {
            addRootFolder(url.path)
        }
    }

    public func addRootFolder(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        guard !config.roots.contains(expanded) else {
            showToast("Folder already watched")
            return
        }
        config.roots.append(expanded)
        config.initialized = true
        persistConfig()
        showToast("Added \(URL(fileURLWithPath: expanded).lastPathComponent)")
        refreshAll()
    }

    public func removeRootFolder(_ path: String) {
        config.roots.removeAll { $0 == path }
        persistConfig()
        showToast("Removed watched folder")
        refreshAll()
    }

    public func rediscoverProjects() {
        refreshAll()
        showToast("Scanning watched folders…")
    }

    public func refreshHookStatuses() {
        let currentProvider = provider
        Task { [weak self] in
            let latest = await Task.detached(priority: .utility) {
                currentProvider.getHookStatuses()
            }.value
            guard let self else { return }
            self.hookStatuses = latest
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
                self.showToast("\(agent.displayName) hook \(enabled ? "installed" : "removed")")
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

    // MARK: Config Persistence Helpers

    private func persistConfig() {
        do {
            try provider.saveConfig(config)
        } catch {
            showToast("Failed to save config: \(error.localizedDescription)", isError: true)
        }
    }

    nonisolated public static func defaultConfigURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/trellis-card/config.json")
    }

    nonisolated public static func loadConfigFallback() -> HUDConfig {
        let url = defaultConfigURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(HUDConfig.self, from: data) else {
            return HUDConfig()
        }
        return decoded
    }

    nonisolated public static func saveConfigFallback(_ cfg: HUDConfig) throws {
        let url = defaultConfigURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cfg)
        try data.write(to: url, options: .atomic)
    }

    nonisolated public static func loadDocumentFallback(taskDir: String, relativePath: String) -> String? {
        let base = URL(fileURLWithPath: taskDir).standardizedFileURL
        let target = base.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path.hasPrefix(base.path) else { return nil }
        return try? String(contentsOf: target, encoding: .utf8)
    }

    nonisolated public static func defaultHookStatuses() -> [AgentHookStatusInfo] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            AgentHookStatusInfo(agent: .claude, installed: false, configExists: false, configPath: "\(home)/.claude/settings.json"),
            AgentHookStatusInfo(agent: .codex, installed: false, configExists: false, configPath: "\(home)/.codex/hooks.json"),
            AgentHookStatusInfo(agent: .cursor, installed: false, configExists: false, configPath: "\(home)/.cursor/hooks.json"),
            AgentHookStatusInfo(agent: .pi, installed: false, configExists: false, configPath: "\(home)/.pi/agent/extensions/trellis-card.ts"),
            AgentHookStatusInfo(agent: .opencode, installed: false, configExists: false, configPath: "\(home)/.config/opencode/plugins/trellis-card.js"),
            AgentHookStatusInfo(agent: .dsh, installed: false, configExists: false, configPath: "\(home)/.config/trellis-card/agents/dsh-trellis-bridge"),
            AgentHookStatusInfo(agent: .antigravity, installed: false, configExists: true, configPath: "\(home)/.gemini/antigravity/brain", isSupported: false, detail: "Observed automatically via trellis mem"),
        ]
    }
}
