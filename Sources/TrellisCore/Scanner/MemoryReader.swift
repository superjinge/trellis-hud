import Foundation

/// Reads `.trellis/workspace/<developer>/journal-*.md` files and queries cross-platform
/// local AI session memory (`trellis mem` CLI + direct local readers for Antigravity, Claude, Codex, Pi).
public enum MemoryReader: Sendable {
    // MARK: - Workspace Journals

    /// Scans `<projectPath>/.trellis/workspace/<developer>/journal-*.md` into `[WorkspaceJournal]`.
    public static func scanJournals(projectPath: String) -> [WorkspaceJournal] {
        let normalizedProject = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
            .standardizedFileURL.path
        let workspaceDir = (normalizedProject as NSString).appendingPathComponent(".trellis/workspace")
        let fm = FileManager.default

        guard let developers = try? fm.contentsOfDirectory(atPath: workspaceDir) else {
            return []
        }

        var journals: [WorkspaceJournal] = []
        for dev in developers where !dev.hasPrefix(".") {
            let devDir = (workspaceDir as NSString).appendingPathComponent(dev)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: devDir, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard let files = try? fm.contentsOfDirectory(atPath: devDir) else { continue }
            for file in files where file.hasPrefix("journal-") && file.hasSuffix(".md") {
                let fullPath = (devDir as NSString).appendingPathComponent(file)
                guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
                    continue
                }
                let indexNum = parseJournalNumber(file)
                let lines = content.components(separatedBy: .newlines)
                let mtime = ((try? fm.attributesOfItem(atPath: fullPath)[.modificationDate]) as? Date) ?? .distantPast
                let (latestHeading, preview) = extractLatestJournalSection(lines: lines)

                journals.append(
                    WorkspaceJournal(
                        developer: dev,
                        fileName: file,
                        filePath: fullPath,
                        indexNumber: indexNum,
                        lineCount: lines.count,
                        mtime: mtime,
                        latestHeading: latestHeading,
                        preview: preview,
                        content: content
                    )
                )
            }
        }

        return journals.sorted { lhs, rhs in
            if lhs.mtime != rhs.mtime { return lhs.mtime > rhs.mtime }
            if lhs.indexNumber != rhs.indexNumber { return lhs.indexNumber > rhs.indexNumber }
            return lhs.developer < rhs.developer
        }
    }

    // MARK: - Cross-Platform Session Memory

    /// Scans recent local AI session files across Antigravity, Claude Code, Codex, and Pi.
    /// Optionally filters to sessions associated with `projectPath`.
    public static func scanLocalSessions(
        projectPath: String? = nil,
        limit: Int = 40,
        homeDirectory: String? = nil
    ) -> [MemorySessionItem] {
        let home = homeDirectory ?? NSHomeDirectory()
        let normalizedTarget = projectPath.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path
        }

        var items: [MemorySessionItem] = []
        items.append(contentsOf: scanAntigravitySessions(home: home, targetCwd: normalizedTarget, limit: limit))
        items.append(contentsOf: scanClaudeSessions(home: home, targetCwd: normalizedTarget, limit: limit))
        items.append(contentsOf: scanCodexSessions(home: home, targetCwd: normalizedTarget, limit: limit))
        items.append(contentsOf: scanPiSessions(home: home, targetCwd: normalizedTarget, limit: limit))

        let sorted = items.sorted { lhs, rhs in
            let lDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let rDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            return lDate > rDate
        }
        return limit > 0 ? Array(sorted.prefix(limit)) : sorted
    }

    /// Searches memory sessions using multi-token case-insensitive AND matching.
    /// Prefers `trellis mem search --json` when available on PATH, falling back to fast direct local scanning.
    public static func searchMemory(
        query: String,
        projectPath: String? = nil,
        limit: Int = 30,
        homeDirectory: String? = nil,
        preferCLI: Bool = false
    ) -> [MemorySessionItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if preferCLI, let cli = queryTrellisMemCLI(query: nil, projectPath: projectPath, limit: limit) {
                return cli
            }
            return scanLocalSessions(projectPath: projectPath, limit: limit, homeDirectory: homeDirectory)
        }

        if preferCLI, let cli = queryTrellisMemCLI(query: trimmed, projectPath: projectPath, limit: limit) {
            return cli
        }

        let tokens = trimmed
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        let candidates = scanLocalSessions(
            projectPath: projectPath,
            limit: max(limit * 4, 120),
            homeDirectory: homeDirectory
        )

        var matches: [MemorySessionItem] = []
        for var session in candidates {
            let corpus = buildSearchCorpus(for: session)
            let lowered = corpus.lowercased()
            guard tokens.allSatisfy({ lowered.contains($0) }) else { continue }

            var hitCount = 0
            for token in tokens {
                hitCount += countOccurrences(of: token, in: lowered)
            }
            let excerpts = extractMatchingSnippets(from: corpus, tokens: tokens, maxSnippets: 3)
            session.matchCount = max(hitCount, excerpts.count)
            session.score = Double(hitCount) + (session.title?.lowercased().contains(tokens[0]) == true ? 5.0 : 0.0)
            if !excerpts.isEmpty {
                session.excerpts = excerpts
            }
            matches.append(session)
        }

        let sorted = matches.sorted { lhs, rhs in
            let ls = lhs.score ?? 0
            let rs = rhs.score ?? 0
            if ls != rs { return ls > rs }
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
        return limit > 0 ? Array(sorted.prefix(limit)) : sorted
    }

    /// Optional CLI bridge to `trellis mem list --json` / `trellis mem search <query> --json`.
    /// Returns `nil` when `trellis` is not installed or exits non-zero.
    public static func queryTrellisMemCLI(
        query: String? = nil,
        projectPath: String? = nil,
        limit: Int = 30,
        timeoutSeconds: Double = 3.0
    ) -> [MemorySessionItem]? {
        guard let trellisBin = resolveTrellisExecutable() else { return nil }

        var args = ["mem"]
        if let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            args.append(contentsOf: ["search", q])
        } else {
            args.append("list")
        }
        if let projectPath, !projectPath.isEmpty {
            args.append(contentsOf: ["--cwd", projectPath])
        } else {
            args.append("--global")
        }
        args.append(contentsOf: ["--limit", String(limit), "--json"])

        guard let output = runCommand(executable: trellisBin, args: args, timeoutSeconds: timeoutSeconds),
              let data = output.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        return decodeTrellisMemJSON(parsed)
    }

    // MARK: - Local Platform Adapters

    private static func scanAntigravitySessions(
        home: String,
        targetCwd: String?,
        limit: Int
    ) -> [MemorySessionItem] {
        let fm = FileManager.default
        var roots: [String] = []
        if let envRoot = ProcessInfo.processInfo.environment["ANTIGRAVITY_BRAIN_DIR"], !envRoot.isEmpty {
            roots.append((envRoot as NSString).expandingTildeInPath)
        }
        roots.append((home as NSString).appendingPathComponent(".gemini/antigravity/brain"))
        roots.append((home as NSString).appendingPathComponent(".gemini/antigravity-cli/brain"))
        roots.append((home as NSString).appendingPathComponent(".gemini/antigravity-ide/brain"))

        var candidates: [(id: String, path: String, mtime: Date)] = []
        var seenIds = Set<String>()

        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for convId in entries where !convId.hasPrefix(".") {
                let transcript = (((root as NSString)
                    .appendingPathComponent(convId) as NSString)
                    .appendingPathComponent(".system_generated/logs/transcript.jsonl"))
                guard fm.fileExists(atPath: transcript), seenIds.insert(convId).inserted else { continue }
                let mtime = ((try? fm.attributesOfItem(atPath: transcript)[.modificationDate]) as? Date) ?? .distantPast
                candidates.append((convId, transcript, mtime))
            }
        }

        candidates.sort { $0.mtime > $1.mtime }
        var items: [MemorySessionItem] = []

        for cand in candidates.prefix(max(limit * 3, 60)) {
            guard let head = readPrefixText(path: cand.path, maxBytes: 48 * 1024) else { continue }
            var createdAt: Date?
            var inferredCwd: String?
            var title: String?
            var excerpts: [MemoryExcerpt] = []

            for line in head.components(separatedBy: .newlines) where !line.isEmpty {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if createdAt == nil, let ts = obj["created_at"] as? String {
                    createdAt = parseISO8601(ts)
                }
                if inferredCwd == nil {
                    inferredCwd = (obj["cwd"] as? String)
                        ?? (obj["workspace_path"] as? String)
                        ?? (obj["workspacePaths"] as? [String])?.first
                        ?? inferCwdFromAntigravityToolCalls(obj["tool_calls"])
                }
                if let type = obj["type"] as? String, let content = obj["content"] as? String {
                    if type == "USER_INPUT" {
                        let cleaned = extractUserRequestText(content)
                        if !cleaned.isEmpty {
                            if title == nil { title = firstLineSummary(cleaned) }
                            if excerpts.count < 2 {
                                excerpts.append(MemoryExcerpt(role: "user", snippet: String(cleaned.prefix(200))))
                            }
                        }
                    } else if type == "PLANNER_RESPONSE", excerpts.count < 2 {
                        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            excerpts.append(MemoryExcerpt(role: "assistant", snippet: String(cleaned.prefix(200))))
                        }
                    }
                }
                if createdAt != nil && inferredCwd != nil && title != nil && excerpts.count >= 2 {
                    break
                }
            }

            if let targetCwd, let inferredCwd, !pathsMatch(inferredCwd, targetCwd) {
                continue
            }
            if targetCwd != nil && inferredCwd == nil {
                continue
            }

            items.append(
                MemorySessionItem(
                    id: cand.id,
                    platform: .antigravity,
                    title: title,
                    cwd: inferredCwd,
                    createdAt: createdAt ?? cand.mtime,
                    updatedAt: cand.mtime,
                    filePath: cand.path,
                    excerpts: excerpts
                )
            )
            if items.count >= limit { break }
        }

        return items
    }

    private static func scanClaudeSessions(
        home: String,
        targetCwd: String?,
        limit: Int
    ) -> [MemorySessionItem] {
        let fm = FileManager.default
        let projectsRoot = (home as NSString).appendingPathComponent(".claude/projects")
        guard fm.fileExists(atPath: projectsRoot) else { return [] }

        let projectDirs: [String]
        if let targetCwd {
            let sanitized = sanitizeClaudeCwd(targetCwd)
            let direct = (projectsRoot as NSString).appendingPathComponent(sanitized)
            projectDirs = fm.fileExists(atPath: direct) ? [direct] : []
        } else {
            let entries = (try? fm.contentsOfDirectory(atPath: projectsRoot)) ?? []
            projectDirs = entries.filter { !$0.hasPrefix(".") }.map {
                (projectsRoot as NSString).appendingPathComponent($0)
            }
        }

        var files: [(id: String, path: String, mtime: Date)] = []
        for dir in projectDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in entries where file.hasSuffix(".jsonl") {
                let full = (dir as NSString).appendingPathComponent(file)
                let mtime = ((try? fm.attributesOfItem(atPath: full)[.modificationDate]) as? Date) ?? .distantPast
                files.append(((file as NSString).deletingPathExtension, full, mtime))
            }
        }

        files.sort { $0.mtime > $1.mtime }
        var items: [MemorySessionItem] = []

        for entry in files.prefix(max(limit * 2, 40)) {
            guard let head = readPrefixText(path: entry.path, maxBytes: 32 * 1024) else { continue }
            var cwd: String? = targetCwd
            var createdAt: Date?
            var title: String?
            var excerpts: [MemoryExcerpt] = []

            for line in head.components(separatedBy: .newlines) where !line.isEmpty {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
                if createdAt == nil, let ts = obj["timestamp"] as? String { createdAt = parseISO8601(ts) }

                if (obj["type"] as? String) == "user",
                   let msg = obj["message"] as? [String: Any],
                   let text = msg["content"] as? String
                {
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        if title == nil { title = firstLineSummary(cleaned) }
                        if excerpts.isEmpty {
                            excerpts.append(MemoryExcerpt(role: "user", snippet: String(cleaned.prefix(200))))
                        }
                    }
                }
                if cwd != nil && createdAt != nil && title != nil { break }
            }

            if let targetCwd, let cwd, !pathsMatch(cwd, targetCwd) { continue }
            items.append(
                MemorySessionItem(
                    id: entry.id,
                    platform: .claude,
                    title: title,
                    cwd: cwd,
                    createdAt: createdAt ?? entry.mtime,
                    updatedAt: entry.mtime,
                    filePath: entry.path,
                    excerpts: excerpts
                )
            )
            if items.count >= limit { break }
        }
        return items
    }

    private static func scanCodexSessions(
        home: String,
        targetCwd: String?,
        limit: Int
    ) -> [MemorySessionItem] {
        let fm = FileManager.default
        let sessionsRoot = (home as NSString).appendingPathComponent(".codex/sessions")
        guard let enumerator = fm.enumerator(atPath: sessionsRoot) else { return [] }

        var files: [(path: String, mtime: Date)] = []
        for case let rel as String in enumerator {
            guard rel.hasSuffix(".jsonl"), (rel as NSString).lastPathComponent.hasPrefix("rollout-") else {
                continue
            }
            let full = (sessionsRoot as NSString).appendingPathComponent(rel)
            let mtime = ((try? fm.attributesOfItem(atPath: full)[.modificationDate]) as? Date) ?? .distantPast
            files.append((full, mtime))
        }

        files.sort { $0.mtime > $1.mtime }
        var items: [MemorySessionItem] = []

        for entry in files.prefix(max(limit * 2, 40)) {
            guard let head = readPrefixText(path: entry.path, maxBytes: 32 * 1024) else { continue }
            var sessionId = (entry.path as NSString).lastPathComponent
            var cwd: String?
            var createdAt: Date?
            var title: String?
            var excerpts: [MemoryExcerpt] = []

            for line in head.components(separatedBy: .newlines) where !line.isEmpty {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if createdAt == nil, let ts = obj["timestamp"] as? String {
                    createdAt = parseISO8601(ts)
                }
                if let payload = obj["payload"] as? [String: Any] {
                    if let id = payload["id"] as? String, !id.isEmpty { sessionId = id }
                    if cwd == nil, let c = payload["cwd"] as? String, !c.isEmpty { cwd = c }
                    if (payload["type"] as? String) == "message",
                       (payload["role"] as? String) == "user",
                       let parts = payload["content"] as? [[String: Any]]
                    {
                        let text = parts.compactMap { part -> String? in
                            guard (part["type"] as? String) == "input_text" else { return nil }
                            return part["text"] as? String
                        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            if title == nil { title = firstLineSummary(text) }
                            if excerpts.isEmpty {
                                excerpts.append(MemoryExcerpt(role: "user", snippet: String(text.prefix(200))))
                            }
                        }
                    }
                }
                if cwd != nil && title != nil { break }
            }

            if let targetCwd {
                guard let cwd, pathsMatch(cwd, targetCwd) else { continue }
            }

            items.append(
                MemorySessionItem(
                    id: sessionId,
                    platform: .codex,
                    title: title,
                    cwd: cwd,
                    createdAt: createdAt ?? entry.mtime,
                    updatedAt: entry.mtime,
                    filePath: entry.path,
                    excerpts: excerpts
                )
            )
            if items.count >= limit { break }
        }
        return items
    }

    private static func scanPiSessions(
        home: String,
        targetCwd: String?,
        limit: Int
    ) -> [MemorySessionItem] {
        let fm = FileManager.default
        let sessionsRoot = (home as NSString).appendingPathComponent(".pi/agent/sessions")
        guard let enumerator = fm.enumerator(atPath: sessionsRoot) else { return [] }

        var files: [(path: String, mtime: Date)] = []
        for case let rel as String in enumerator where rel.hasSuffix(".jsonl") {
            let full = (sessionsRoot as NSString).appendingPathComponent(rel)
            let mtime = ((try? fm.attributesOfItem(atPath: full)[.modificationDate]) as? Date) ?? .distantPast
            files.append((full, mtime))
        }

        files.sort { $0.mtime > $1.mtime }
        var items: [MemorySessionItem] = []

        for entry in files.prefix(max(limit * 2, 40)) {
            guard let head = readPrefixText(path: entry.path, maxBytes: 24 * 1024) else { continue }
            let lines = head.components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard let firstLine = lines.first,
                  let firstData = firstLine.data(using: .utf8),
                  let header = try? JSONSerialization.jsonObject(with: firstData) as? [String: Any],
                  (header["type"] as? String) == "session"
            else { continue }

            let id = (header["id"] as? String) ?? ((entry.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let cwd = header["cwd"] as? String
            let createdAt = (header["timestamp"] as? String).flatMap(parseISO8601) ?? entry.mtime

            if let targetCwd {
                guard let cwd, pathsMatch(cwd, targetCwd) else { continue }
            }

            var title: String?
            for line in lines.dropFirst() {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["type"] as? String) == "session_info",
                      let name = obj["name"] as? String, !name.isEmpty
                else { continue }
                title = name
            }

            items.append(
                MemorySessionItem(
                    id: id,
                    platform: .pi,
                    title: title,
                    cwd: cwd,
                    createdAt: createdAt,
                    updatedAt: entry.mtime,
                    filePath: entry.path
                )
            )
            if items.count >= limit { break }
        }
        return items
    }

    // MARK: - Private Helpers

    private static func parseJournalNumber(_ fileName: String) -> Int {
        let stem = (fileName as NSString).deletingPathExtension
        if stem.hasPrefix("journal-"), let num = Int(stem.dropFirst("journal-".count)) {
            return num
        }
        return 1
    }

    private static func extractLatestJournalSection(lines: [String]) -> (String?, String) {
        var latestHeadingIndex: Int?
        var latestHeading: String?

        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                latestHeadingIndex = idx
                latestHeading = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        }

        let start = latestHeadingIndex.map { $0 + 1 } ?? 0
        var previewLines: [String] = []
        for idx in start..<lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("<!--") || trimmed == "---" { continue }
            previewLines.append(trimmed)
            if previewLines.count >= 4 { break }
        }

        let preview = previewLines.joined(separator: " ")
        return (latestHeading, String(preview.prefix(240)))
    }

    private static func readPrefixText(path: String, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func buildSearchCorpus(for session: MemorySessionItem) -> String {
        var parts: [String] = []
        if let title = session.title { parts.append(title) }
        if let cwd = session.cwd { parts.append(cwd) }
        for ex in session.excerpts { parts.append(ex.snippet) }
        if let body = readPrefixText(path: session.filePath, maxBytes: 128 * 1024) {
            parts.append(body)
        }
        return parts.joined(separator: "\n")
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
            if count >= 50 { break }
        }
        return count
    }

    private static func extractMatchingSnippets(
        from corpus: String,
        tokens: [String],
        maxSnippets: Int
    ) -> [MemoryExcerpt] {
        var excerpts: [MemoryExcerpt] = []
        for line in corpus.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 8 else { continue }
            let lower = trimmed.lowercased()
            if tokens.contains(where: { lower.contains($0) }) {
                let snippet = String(trimmed.prefix(220))
                excerpts.append(MemoryExcerpt(role: "match", snippet: snippet))
                if excerpts.count >= maxSnippets { break }
            }
        }
        return excerpts
    }

    private static func extractUserRequestText(_ raw: String) -> String {
        if let open = raw.range(of: "<USER_REQUEST>"),
           let close = raw.range(of: "</USER_REQUEST>", range: open.upperBound..<raw.endIndex)
        {
            return String(raw[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inferCwdFromAntigravityToolCalls(_ raw: Any?) -> String? {
        guard let calls = raw as? [[String: Any]] else { return nil }
        let fm = FileManager.default
        for call in calls {
            guard let args = call["args"] as? [String: Any] else { continue }
            for key in ["Path", "path", "Cwd", "cwd", "DirectoryPath"] {
                guard let candidate = args[key] as? String, candidate.hasPrefix("/") else { continue }
                if candidate.contains("/.gemini/antigravity") || candidate.contains("/.agents/skills/") {
                    continue
                }
                var cur = URL(fileURLWithPath: candidate).standardizedFileURL
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: cur.path, isDirectory: &isDir), !isDir.boolValue {
                    cur = cur.deletingLastPathComponent()
                }
                while cur.path != "/" {
                    if fm.fileExists(atPath: cur.appendingPathComponent(".trellis").path)
                        || fm.fileExists(atPath: cur.appendingPathComponent(".git").path)
                    {
                        return cur.path
                    }
                    cur = cur.deletingLastPathComponent()
                }
            }
        }
        return nil
    }

    private static func firstLineSummary(_ text: String) -> String? {
        guard let line = text.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        return line.count > 80 ? String(line.prefix(77)) + "..." : line
    }

    private static func sanitizeClaudeCwd(_ cwd: String) -> String {
        var out = ""
        for ch in cwd {
            if ch == "/" || ch == "_" { out.append("-") } else { out.append(ch) }
        }
        return out
    }

    private static func pathsMatch(_ a: String, _ b: String) -> Bool {
        let na = URL(fileURLWithPath: a).standardizedFileURL.path
        let nb = URL(fileURLWithPath: b).standardizedFileURL.path
        return na == nb || na.hasPrefix(nb + "/")
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: value) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: value)
    }

    private static func resolveTrellisExecutable() -> String? {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/trellis",
            "/usr/local/bin/trellis",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/trellis"),
            (NSHomeDirectory() as NSString).appendingPathComponent(".npm-global/bin/trellis"),
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = (String(dir) as NSString).appendingPathComponent("trellis")
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    private static func runCommand(executable: String, args: [String], timeoutSeconds: Double) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        if sem.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            _ = sem.wait(timeout: .now() + 0.5)
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func decodeTrellisMemJSON(_ json: Any) -> [MemorySessionItem] {
        let rows: [[String: Any]]
        if let arr = json as? [[String: Any]] {
            rows = arr
        } else if let dict = json as? [String: Any], let arr = dict["matches"] as? [[String: Any]] {
            rows = arr
        } else if let dict = json as? [String: Any], let arr = dict["sessions"] as? [[String: Any]] {
            rows = arr
        } else {
            return []
        }

        return rows.compactMap { row -> MemorySessionItem? in
            let sessionObj = (row["session"] as? [String: Any]) ?? row
            guard let id = sessionObj["id"] as? String else { return nil }
            let platform = MemoryPlatform.from(raw: (sessionObj["platform"] as? String) ?? "unknown")
            let title = sessionObj["title"] as? String
            let cwd = sessionObj["cwd"] as? String
            let filePath = (sessionObj["filePath"] as? String) ?? ""
            let createdAt = (sessionObj["created"] as? String).flatMap(parseISO8601)
            let updatedAt = (sessionObj["updated"] as? String).flatMap(parseISO8601)
            let score = row["score"] as? Double
            let hitCount = (row["hitCount"] as? Int) ?? (row["matchCount"] as? Int) ?? 0
            let rawExcerpts = (row["excerpts"] as? [[String: Any]]) ?? []
            let excerpts = rawExcerpts.compactMap { ex -> MemoryExcerpt? in
                guard let snippet = (ex["snippet"] as? String) ?? (ex["text"] as? String) else { return nil }
                return MemoryExcerpt(role: (ex["role"] as? String) ?? "match", snippet: snippet)
            }
            return MemorySessionItem(
                id: id,
                platform: platform,
                title: title,
                cwd: cwd,
                createdAt: createdAt,
                updatedAt: updatedAt,
                filePath: filePath,
                score: score,
                matchCount: hitCount,
                excerpts: excerpts
            )
        }
    }
}
