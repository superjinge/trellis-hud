import Foundation

/// Discovers Trellis projects and scans active/archived tasks, artifacts, real Markdown checklists,
/// and accurate workflow phases.
public enum ProjectScanner: Sendable {
    public static let skippedDirectories: Set<String> = [
        ".git",
        "node_modules",
        "target",
        ".build",
        "build",
        "dist",
        ".next",
        "__pycache__",
        "DerivedData",
    ]

    private static let maxDocumentBytes = 512 * 1024

    // MARK: - Project Discovery

    /// Performs a breadth-first search under each root (up to `maxDepth`) to find Trellis projects
    /// containing `.trellis/tasks/`. Deduplicates canonical directory paths to prevent symlink cycles
    /// and continues descending inside discovered projects to find nested monorepo sub-projects.
    public static func discoverProjects(roots: [String], maxDepth: Int = 3) -> [ProjectInfo] {
        let fm = FileManager.default
        var seenProjects = Set<String>()
        var visitedDirs = Set<String>()
        var discovered: [ProjectInfo] = []

        for rawRoot in roots {
            let rootPath = ConfigStore.normalizePath(rawRoot)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard visitedDirs.insert(rootPath).inserted else {
                continue
            }

            var queue: [(path: String, depth: Int)] = [(rootPath, 0)]
            var head = 0

            while head < queue.count {
                let current = queue[head]
                head += 1

                if current.depth > maxDepth {
                    continue
                }

                let tasksDir = (current.path as NSString).appendingPathComponent(".trellis/tasks")
                var tasksIsDir: ObjCBool = false
                if fm.fileExists(atPath: tasksDir, isDirectory: &tasksIsDir), tasksIsDir.boolValue {
                    if seenProjects.insert(current.path).inserted {
                        discovered.append(scanProjectInfo(projectPath: current.path))
                    }
                }

                guard current.depth < maxDepth else { continue }
                guard let children = try? fm.contentsOfDirectory(atPath: current.path) else {
                    continue
                }

                for entry in children {
                    if entry.hasPrefix(".") || skippedDirectories.contains(entry) {
                        continue
                    }
                    let rawChildPath = (current.path as NSString).appendingPathComponent(entry)
                    let canonicalChild = ConfigStore.normalizePath(rawChildPath)
                    var childIsDir: ObjCBool = false
                    guard fm.fileExists(atPath: canonicalChild, isDirectory: &childIsDir), childIsDir.boolValue else {
                        continue
                    }
                    guard visitedDirs.insert(canonicalChild).inserted else {
                        continue
                    }
                    queue.append((canonicalChild, current.depth + 1))
                }
            }
        }

        return discovered.sorted { lhs, rhs in
            let lDate = lhs.lastActivity ?? .distantPast
            let rDate = rhs.lastActivity ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Computes summary metadata (`ProjectInfo`) for a single Trellis project directory.
    public static func scanProjectInfo(projectPath: String) -> ProjectInfo {
        let normalized = ConfigStore.normalizePath(projectPath)
        let active = scanActiveTasks(projectPath: normalized)
        let archivedCount = countArchivedTasks(projectPath: normalized)
        let lastActivity = active.map(\.mtime).max()
        let name = URL(fileURLWithPath: normalized).lastPathComponent

        return ProjectInfo(
            name: name,
            path: normalized,
            activeTaskCount: active.count,
            archivedTaskCount: archivedCount,
            lastActivity: lastActivity == .distantPast ? nil : lastActivity
        )
    }

    // MARK: - Task Scanning

    /// Scans all active (non-archived) tasks under `<projectPath>/.trellis/tasks/`.
    public static func scanActiveTasks(projectPath: String) -> [TaskSnapshot] {
        let normalizedProject = ConfigStore.normalizePath(projectPath)
        let tasksDir = (normalizedProject as NSString).appendingPathComponent(".trellis/tasks")
        let fm = FileManager.default

        guard let entries = try? fm.contentsOfDirectory(atPath: tasksDir) else {
            return []
        }

        let projectName = URL(fileURLWithPath: normalizedProject).lastPathComponent
        let sessionsByTask = scanRuntimeSessions(projectPath: normalizedProject)
        let devWorkflow = readDeveloperWorkflow(projectPath: normalizedProject)
        let configWorkflow = readConfigDefaultWorkflow(projectPath: normalizedProject)

        var snapshots: [TaskSnapshot] = []
        for entry in entries {
            if entry == "archive" || entry.hasPrefix(".") || isBootstrapGuidelines(entry) {
                continue
            }
            let fullDir = (tasksDir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullDir, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if let snapshot = scanTaskDirectory(
                dirName: entry,
                relativeDir: entry,
                fullTaskDir: fullDir,
                archived: false,
                projectName: projectName,
                projectPath: normalizedProject,
                sessionsByTask: sessionsByTask,
                developerWorkflow: devWorkflow,
                configWorkflow: configWorkflow
            ) {
                snapshots.append(snapshot)
            }
        }

        return snapshots.sorted { lhs, rhs in
            if lhs.mtime != rhs.mtime { return lhs.mtime > rhs.mtime }
            return lhs.dir > rhs.dir
        }
    }

    /// Recursively scans archived tasks under `<projectPath>/.trellis/tasks/archive/`.
    public static func scanArchivedTasks(projectPath: String) -> [TaskSnapshot] {
        let normalizedProject = ConfigStore.normalizePath(projectPath)
        let tasksDir = (normalizedProject as NSString).appendingPathComponent(".trellis/tasks")
        let archiveDir = (tasksDir as NSString).appendingPathComponent("archive")
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: archiveDir, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let projectName = URL(fileURLWithPath: normalizedProject).lastPathComponent
        let devWorkflow = readDeveloperWorkflow(projectPath: normalizedProject)
        let configWorkflow = readConfigDefaultWorkflow(projectPath: normalizedProject)

        var snapshots: [TaskSnapshot] = []
        scanArchiveRecursive(
            tasksDir: tasksDir,
            currentDir: archiveDir,
            projectName: projectName,
            projectPath: normalizedProject,
            developerWorkflow: devWorkflow,
            configWorkflow: configWorkflow,
            into: &snapshots
        )

        return snapshots.sorted { lhs, rhs in
            let lKey = lhs.record.completedAt ?? lhs.record.createdAt ?? ""
            let rKey = rhs.record.completedAt ?? rhs.record.createdAt ?? ""
            if lKey != rKey { return lKey > rKey }
            if lhs.mtime != rhs.mtime { return lhs.mtime > rhs.mtime }
            return lhs.dir > rhs.dir
        }
    }

    /// Safely loads a Markdown or text document inside `taskDir` with full symlink-resolved
    /// path-traversal protection (symlinks escaping `taskDir` are rejected).
    public static func loadTaskDocument(taskDir: String, relativePath: String) -> String? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }

        let normalizedRel = trimmed.replacingOccurrences(of: "\\", with: "/")
        let components = normalizedRel.split(separator: "/").map(String.init)
        guard !components.contains(".."), !components.isEmpty else { return nil }

        let rawBaseURL = URL(fileURLWithPath: taskDir, isDirectory: true)
        let resolvedBaseURL = rawBaseURL.resolvingSymlinksInPath().standardizedFileURL
        let rawTargetURL = resolvedBaseURL.appendingPathComponent(normalizedRel)
        let resolvedTargetURL = rawTargetURL.resolvingSymlinksInPath().standardizedFileURL

        let basePath = resolvedBaseURL.path.hasSuffix("/")
            ? resolvedBaseURL.path
            : resolvedBaseURL.path + "/"
        guard resolvedTargetURL.path.hasPrefix(basePath) else { return nil }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedTargetURL.path, isDirectory: &isDir),
              !isDir.boolValue
        else { return nil }

        guard let data = try? Data(contentsOf: resolvedTargetURL) else { return nil }
        if data.count > maxDocumentBytes {
            let sliced = data.prefix(maxDocumentBytes)
            let text = String(decoding: sliced, as: UTF8.self)
            return text + "\n\n… (Document truncated at 512 KB)"
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Resolves the active Trellis task directory for a project by checking `.trellis/.runtime/sessions/*.json`
    /// and falling back to `.trellis/.current-task`.
    public static func resolveCurrentTaskDir(projectPath: String) -> String? {
        let normalizedProject = ConfigStore.normalizePath(projectPath)
        let sessionsDir = (normalizedProject as NSString).appendingPathComponent(".trellis/.runtime/sessions")
        let fm = FileManager.default

        if let files = try? fm.contentsOfDirectory(atPath: sessionsDir) {
            var newest: (lastSeen: String, taskDir: String)?
            for file in files where file.hasSuffix(".json") {
                let fullPath = (sessionsDir as NSString).appendingPathComponent(file)
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawTask = (json["current_task"] as? String) ?? (json["currentTask"] as? String),
                      let taskDir = extractTaskDirComponent(from: rawTask)
                else { continue }

                let lastSeen = (json["last_seen_at"] as? String) ?? (json["lastSeenAt"] as? String) ?? ""
                if newest == nil || lastSeen > newest!.lastSeen {
                    newest = (lastSeen, taskDir)
                }
            }
            if let winner = newest {
                return winner.taskDir
            }
        }

        let pointerFile = (normalizedProject as NSString).appendingPathComponent(".trellis/.current-task")
        if let raw = try? String(contentsOfFile: pointerFile, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let dir = extractTaskDirComponent(from: trimmed) {
                return dir
            }
        }
        return nil
    }

    // MARK: - Internal / Private Helpers

    private static func scanArchiveRecursive(
        tasksDir: String,
        currentDir: String,
        projectName: String,
        projectPath: String,
        developerWorkflow: String?,
        configWorkflow: String?,
        into snapshots: inout [TaskSnapshot]
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: currentDir) else { return }

        for entry in entries {
            if entry.hasPrefix(".") || isBootstrapGuidelines(entry) { continue }
            let path = (currentDir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }

            let taskJsonPath = (path as NSString).appendingPathComponent("task.json")
            if fm.fileExists(atPath: taskJsonPath) {
                let relDir = relativePath(from: tasksDir, to: path)
                if let snapshot = scanTaskDirectory(
                    dirName: entry,
                    relativeDir: relDir,
                    fullTaskDir: path,
                    archived: true,
                    projectName: projectName,
                    projectPath: projectPath,
                    sessionsByTask: [:],
                    developerWorkflow: developerWorkflow,
                    configWorkflow: configWorkflow
                ) {
                    snapshots.append(snapshot)
                }
            } else {
                scanArchiveRecursive(
                    tasksDir: tasksDir,
                    currentDir: path,
                    projectName: projectName,
                    projectPath: projectPath,
                    developerWorkflow: developerWorkflow,
                    configWorkflow: configWorkflow,
                    into: &snapshots
                )
            }
        }
    }

    private static func countArchivedTasks(projectPath: String) -> Int {
        let archiveDir = (projectPath as NSString).appendingPathComponent(".trellis/tasks/archive")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: archiveDir) else { return 0 }
        var count = 0
        for case let rel as String in enumerator {
            if (rel as NSString).lastPathComponent == "task.json" {
                let parentName = ((rel as NSString).deletingLastPathComponent as NSString).lastPathComponent
                if !isBootstrapGuidelines(parentName) {
                    count += 1
                }
            }
        }
        return count
    }

    private static func scanTaskDirectory(
        dirName: String,
        relativeDir: String,
        fullTaskDir: String,
        archived: Bool,
        projectName: String,
        projectPath: String,
        sessionsByTask: [String: [String]],
        developerWorkflow: String?,
        configWorkflow: String?
    ) -> TaskSnapshot? {
        let taskJsonPath = (fullTaskDir as NSString).appendingPathComponent("task.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: taskJsonPath)),
              var record = try? JSONDecoder().decode(TaskRecord.self, from: data)
        else {
            return nil
        }

        if record.id.isEmpty { record.id = dirName }
        if record.name.isEmpty { record.name = record.id }
        if record.title.isEmpty { record.title = record.id }
        record.workflow = resolveWorkflow(
            taskWorkflow: record.workflow,
            developerWorkflow: developerWorkflow,
            configWorkflow: configWorkflow
        )

        // Read `prd.md` once per task and reuse across artifacts, checklists, excerpt, and cross-task refs.
        let prdPath = (fullTaskDir as NSString).appendingPathComponent("prd.md")
        let prdContent = try? String(contentsOfFile: prdPath, encoding: .utf8)

        let artifacts = scanArtifacts(taskDir: fullTaskDir, prdContent: prdContent)
        let checklist = MarkdownChecklistParser.parseTaskChecklists(
            taskDir: fullTaskDir,
            preloadedPrdContent: prdContent ?? ""
        )

        let excerpt: String
        if let prdContent, !prdContent.isEmpty {
            excerpt = MarkdownChecklistParser.extractExcerpt(markdown: prdContent)
        } else {
            excerpt = record.description
        }

        let (phase, phaseWarning) = inferWorkflowPhase(
            status: record.status,
            archived: archived,
            artifacts: artifacts,
            checklist: checklist
        )

        let progress = computeHonestProgress(
            status: record.status,
            archived: archived,
            checklist: checklist,
            subtasks: record.subtasks
        )

        let mtime = computeMaxMtime(taskDir: fullTaskDir, taskJsonPath: taskJsonPath)
        let activeSessions = archived ? [] : (sessionsByTask[dirName] ?? sessionsByTask[record.id] ?? [])

        return TaskSnapshot(
            projectName: projectName,
            projectPath: projectPath,
            dir: relativeDir,
            archived: archived,
            record: record,
            phase: phase,
            phaseWarning: phaseWarning,
            checklist: checklist,
            progress: progress,
            artifacts: artifacts,
            excerpt: excerpt,
            mtime: mtime,
            activeSessionIds: activeSessions
        )
    }

    private static func scanArtifacts(taskDir: String, prdContent: String?) -> TaskArtifacts {
        let fm = FileManager.default
        let hasPrd = prdContent != nil || fm.fileExists(atPath: (taskDir as NSString).appendingPathComponent("prd.md"))
        let hasDesign = fm.fileExists(atPath: (taskDir as NSString).appendingPathComponent("design.md"))
        let hasImplement = fm.fileExists(atPath: (taskDir as NSString).appendingPathComponent("implement.md"))

        var docNames: [String] = []
        var reportCount = 0
        if let rootEntries = try? fm.contentsOfDirectory(atPath: taskDir) {
            for name in rootEntries where name.hasSuffix(".md") {
                let path = (taskDir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                    docNames.append(name)
                    if name.hasPrefix("acceptance-report") {
                        reportCount += 1
                    }
                }
            }
        }

        var researchCount = 0
        let researchDir = (taskDir as NSString).appendingPathComponent("research")
        if let resEntries = try? fm.contentsOfDirectory(atPath: researchDir) {
            for name in resEntries where name.hasSuffix(".md") {
                let path = (researchDir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                    researchCount += 1
                    docNames.append("research/\(name)")
                }
            }
        }

        docNames.sort { lhs, rhs in
            let lr = documentRank(lhs)
            let rr = documentRank(rhs)
            if lr != rr { return lr < rr }
            return lhs < rhs
        }

        let implEntries = collectJsonlFileRefs(path: (taskDir as NSString).appendingPathComponent("implement.jsonl"))
        let checkEntries = collectJsonlFileRefs(path: (taskDir as NSString).appendingPathComponent("check.jsonl"))

        var seenFiles = Set<String>()
        var fileRefs: [String] = []
        for ref in implEntries + checkEntries where seenFiles.insert(ref).inserted {
            fileRefs.append(ref)
        }
        let specRefs = fileRefs.filter(isSpecRef)
        let prdRefs = prdContent.map(collectPrdTaskRefs(from:)) ?? []

        return TaskArtifacts(
            hasPrd: hasPrd,
            hasDesign: hasDesign,
            hasImplement: hasImplement,
            researchCount: researchCount,
            implContextCount: implEntries.count,
            checkContextCount: checkEntries.count,
            reportCount: reportCount,
            documentPaths: docNames,
            specRefs: specRefs,
            fileRefs: fileRefs,
            prdRefs: prdRefs
        )
    }

    private static func documentRank(_ name: String) -> Int {
        switch name {
        case "prd.md": return 0
        case "design.md": return 1
        case "implement.md": return 2
        default:
            if name.hasPrefix("acceptance-report") { return 3 }
            if name.hasPrefix("research/") { return 4 }
            return 5
        }
    }

    private static func collectJsonlFileRefs(path: String) -> [String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        var refs: [String] = []

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let file = obj["file"] as? String,
                  !file.isEmpty
            else { continue }
            let normalized = file.replacingOccurrences(of: "\\", with: "/")
            if seen.insert(normalized).inserted {
                refs.append(normalized)
            }
        }
        return refs
    }

    private static func isSpecRef(_ path: String) -> Bool {
        let norm = path.replacingOccurrences(of: "\\", with: "/")
        return norm.hasPrefix(".trellis/spec/") || norm.hasPrefix("spec/") || norm.contains("/spec/")
    }

    private static func collectPrdTaskRefs(from content: String) -> [String] {
        let marker = ".trellis/tasks/"
        let delimiters = CharacterSet(charactersIn: "/ `)\"'")

        var seen = Set<String>()
        var refs: [String] = []
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\\", with: "/")
            var searchStart = line.startIndex
            while let range = line.range(of: marker, range: searchStart..<line.endIndex) {
                let rest = line[range.upperBound...]
                let token = String(rest.prefix { ch in
                    !ch.unicodeScalars.allSatisfy { delimiters.contains($0) }
                })
                if !token.isEmpty && token != "archive" && seen.insert(token).inserted {
                    refs.append(token)
                }
                searchStart = range.upperBound
            }
        }
        return refs
    }

    /// Infers the 5-step workflow phase (`explore → plan → implement → check → archive`)
    /// strictly from durable task status, artifacts, and checklists.
    public static func inferWorkflowPhase(
        status: String,
        archived: Bool,
        artifacts: TaskArtifacts,
        checklist: [ChecklistItem]
    ) -> (WorkflowPhase, String?) {
        let normalized = status.lowercased()
        if archived || normalized == "completed" || normalized == "done" {
            return (.archive, nil)
        }
        if normalized == "review" {
            return (.check, nil)
        }
        if normalized == "blocked" {
            return (.implement, "Task is marked blocked")
        }
        if normalized == "failed" {
            return (.check, "Task is marked failed")
        }
        if normalized == "in_progress" {
            let implItems = checklist.filter { $0.sourceFile == "implement.md" }
            let allImplComplete = !implItems.isEmpty && implItems.allSatisfy(\.isCompleted)
            if artifacts.reportCount > 0 || allImplComplete {
                return (.check, nil)
            }
            return (.implement, nil)
        }
        if !artifacts.hasPrd {
            return (.explore, nil)
        }
        if artifacts.implContextCount == 0 && artifacts.checkContextCount == 0 {
            return (.plan, "Context manifests (implement.jsonl / check.jsonl) have no real entries")
        }
        return (.plan, nil)
    }

    /// Computes honest progress from real checklists (or legacy status-bearing subtasks).
    /// Returns `0.0` when no measurable checklist exists — never fabricates 10%/50%/85% percentages.
    public static func computeHonestProgress(
        status: String,
        archived: Bool,
        checklist: [ChecklistItem],
        subtasks: [TaskSubtask]
    ) -> Double {
        let normalized = status.lowercased()
        if archived || normalized == "completed" || normalized == "done" {
            return 1.0
        }
        if !checklist.isEmpty {
            let done = checklist.filter(\.isCompleted).count
            return Double(done) / Double(checklist.count)
        }
        let legacyWithStatus = subtasks.filter { $0.status != nil }
        if !legacyWithStatus.isEmpty {
            let done = legacyWithStatus.filter(\.isCompleted).count
            return Double(done) / Double(legacyWithStatus.count)
        }
        return 0.0
    }

    private static func scanRuntimeSessions(projectPath: String) -> [String: [String]] {
        let dir = (projectPath as NSString).appendingPathComponent(".trellis/.runtime/sessions")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [:] }

        var map: [String: [String]] = [:]
        for entry in entries where entry.hasSuffix(".json") {
            let full = (dir as NSString).appendingPathComponent(entry)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawTask = (json["current_task"] as? String) ?? (json["currentTask"] as? String),
                  let taskDir = extractTaskDirComponent(from: rawTask)
            else { continue }

            let sessionId = (json["session_id"] as? String)
                ?? (entry as NSString).deletingPathExtension
            map[taskDir, default: []].append(sessionId)
        }
        return map
    }

    private static func extractTaskDirComponent(from raw: String) -> String? {
        let norm = raw.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !norm.isEmpty else { return nil }
        if let range = norm.range(of: ".trellis/tasks/") {
            let tail = norm[range.upperBound...]
            let first = tail.split(separator: "/").first.map(String.init)
            return first?.isEmpty == false ? first : nil
        }
        let last = norm.split(separator: "/").last.map(String.init)
        return last?.isEmpty == false ? last : nil
    }

    private static func readDeveloperWorkflow(projectPath: String) -> String? {
        let devFile = (projectPath as NSString).appendingPathComponent(".trellis/.developer")
        guard let content = try? String(contentsOfFile: devFile, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("workflow=") {
                let candidate = String(trimmed.dropFirst("workflow=".count)).trimmingCharacters(in: .whitespaces)
                if isValidWorkflowId(candidate) { return candidate }
            }
        }
        return nil
    }

    private static func readConfigDefaultWorkflow(projectPath: String) -> String? {
        let configFile = (projectPath as NSString).appendingPathComponent(".trellis/config.yaml")
        guard let content = try? String(contentsOfFile: configFile, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("default_workflow:") {
                let raw = String(trimmed.dropFirst("default_workflow:".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                if isValidWorkflowId(raw) { return raw }
            }
        }
        return nil
    }

    private static func resolveWorkflow(
        taskWorkflow: String?,
        developerWorkflow: String?,
        configWorkflow: String?
    ) -> String? {
        for candidate in [taskWorkflow, developerWorkflow, configWorkflow] {
            if let value = candidate?.trimmingCharacters(in: .whitespaces), isValidWorkflowId(value) {
                return value
            }
        }
        return nil
    }

    private static func isValidWorkflowId(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static func isBootstrapGuidelines(_ dirName: String) -> Bool {
        dirName == "00-bootstrap-guidelines" || dirName.hasSuffix("bootstrap-guidelines")
    }

    private static func computeMaxMtime(taskDir: String, taskJsonPath: String) -> Date {
        let fm = FileManager.default
        var latest = fileModDate(taskJsonPath, fm: fm) ?? .distantPast

        if let entries = try? fm.contentsOfDirectory(atPath: taskDir) {
            for name in entries where name.hasSuffix(".md") || name.hasSuffix(".jsonl") {
                let path = (taskDir as NSString).appendingPathComponent(name)
                if let d = fileModDate(path, fm: fm), d > latest { latest = d }
            }
        }

        let researchDir = (taskDir as NSString).appendingPathComponent("research")
        if let entries = try? fm.contentsOfDirectory(atPath: researchDir) {
            for name in entries where name.hasSuffix(".md") {
                let path = (researchDir as NSString).appendingPathComponent(name)
                if let d = fileModDate(path, fm: fm), d > latest { latest = d }
            }
        }
        return latest
    }

    private static func fileModDate(_ path: String, fm: FileManager) -> Date? {
        (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    private static func relativePath(from base: String, to target: String) -> String {
        let b = base.hasSuffix("/") ? base : base + "/"
        if target.hasPrefix(b) {
            return String(target.dropFirst(b.count))
        }
        return URL(fileURLWithPath: target).lastPathComponent
    }
}
