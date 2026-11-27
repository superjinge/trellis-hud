import Foundation

/// Combined git + spec governance report for a Trellis project.
public struct SpecGovernanceReport: Sendable, Codable, Equatable {
    public var specs: [SpecDocument]
    public var gitStatus: GitStatusSnapshot
    public var uncoveredModifiedFiles: [String]

    public init(
        specs: [SpecDocument] = [],
        gitStatus: GitStatusSnapshot,
        uncoveredModifiedFiles: [String] = []
    ) {
        self.specs = specs
        self.gitStatus = gitStatus
        self.uncoveredModifiedFiles = uncoveredModifiedFiles
    }
}

/// Recursively scans `.trellis/spec/**/*.md` at any depth (supporting 2-level and 3-level monorepos),
/// captures lightweight git status/worktree state, and matches actual git-modified files against spec `paths:` globs.
public enum SpecAndGitAnalyzer: Sendable {
    // MARK: - Glob Matching (`*`, `**`, `?`)

    /// Matches a POSIX-normalized relative path against a glob pattern supporting `*`, `**`, and `?`.
    public static func matchesGlob(pattern: String, path: String) -> Bool {
        let normPattern = normalizeRelPath(pattern)
        let normPath = normalizeRelPath(path)
        guard !normPattern.isEmpty, !normPath.isEmpty else { return false }
        if normPattern == normPath { return true }

        let regexPattern = globToRegex(normPattern)
        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: []) else {
            return false
        }
        let range = NSRange(normPath.startIndex..<normPath.endIndex, in: normPath)
        return regex.firstMatch(in: normPath, options: [], range: range) != nil
    }

    // MARK: - Recursive Spec Scanning (2-level & 3-level Monorepo)

    /// Recursively scans `<projectPath>/.trellis/spec/**/*.md`, computes health/template status,
    /// extracts YAML frontmatter `paths:` globs, and matches them against `modifiedFiles`.
    public static func scanSpecs(
        projectPath: String,
        modifiedFiles: [String] = [],
        referencedSpecPaths: [String] = []
    ) -> [SpecDocument] {
        let normalizedProject = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
            .standardizedFileURL.path
        let specRoot = (normalizedProject as NSString).appendingPathComponent(".trellis/spec")
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: specRoot, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        // Count task references to each spec path (normalized both with and without `.trellis/spec/`).
        var refCounts: [String: Int] = [:]
        for rawRef in referencedSpecPaths {
            let norm = normalizeRelPath(rawRef)
            refCounts[norm, default: 0] += 1
            if norm.hasPrefix(".trellis/spec/") {
                let stripped = String(norm.dropFirst(".trellis/spec/".count))
                refCounts[stripped, default: 0] += 1
            } else if norm.hasPrefix("spec/") {
                let stripped = String(norm.dropFirst("spec/".count))
                refCounts[stripped, default: 0] += 1
            }
        }

        let normalizedModified = modifiedFiles.map(normalizeRelPath)
        var documents: [SpecDocument] = []

        guard let enumerator = fm.enumerator(atPath: specRoot) else { return [] }
        for case let relInsideSpec as String in enumerator {
            let posixRel = relInsideSpec.replacingOccurrences(of: "\\", with: "/")
            let parts = posixRel.split(separator: "/").map(String.init)
            if parts.contains(where: { $0.hasPrefix(".") }) {
                continue
            }
            guard posixRel.hasSuffix(".md") else { continue }

            let absPath = (specRoot as NSString).appendingPathComponent(posixRel)
            var itemIsDir: ObjCBool = false
            guard fm.fileExists(atPath: absPath, isDirectory: &itemIsDir), !itemIsDir.boolValue else {
                continue
            }

            let content = (try? String(contentsOfFile: absPath, encoding: .utf8)) ?? ""
            let fileName = parts.last ?? posixRel
            let dirParts = Array(parts.dropLast())

            let packageName: String?
            let layer: String?
            let category: String
            switch dirParts.count {
            case 0:
                packageName = nil
                layer = nil
                category = "general"
            case 1:
                packageName = nil
                layer = dirParts[0]
                category = dirParts[0]
            default:
                packageName = dirParts[0]
                layer = dirParts[1]
                category = dirParts.joined(separator: "/")
            }

            let displayName: String
            if fileName == "index.md" {
                displayName = dirParts.last ?? "index"
            } else {
                displayName = String(fileName.dropLast(3))
            }

            let (lineCount, isEmptyTemplate) = evaluateSpecHealth(content: content)
            let pathGlobs = MarkdownChecklistParser.extractFrontmatterPaths(markdown: content)
            let matched = pathGlobs.isEmpty
                ? []
                : normalizedModified.filter { modFile in
                    pathGlobs.contains { glob in matchesGlob(pattern: glob, path: modFile) }
                }

            let fullRelPath = ".trellis/spec/\(posixRel)"
            let refCount = max(refCounts[fullRelPath] ?? 0, refCounts[posixRel] ?? 0)

            documents.append(
                SpecDocument(
                    relativePath: fullRelPath,
                    absolutePath: absPath,
                    name: displayName,
                    category: category,
                    packageName: packageName,
                    layer: layer,
                    lineCount: lineCount,
                    isEmptyTemplate: isEmptyTemplate,
                    pathGlobs: pathGlobs,
                    matchedModifiedFiles: matched,
                    referencedByTaskCount: refCount,
                    content: content
                )
            )
        }

        return documents.sorted { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category < rhs.category }
            return lhs.relativePath < rhs.relativePath
        }
    }

    // MARK: - Lightweight Git Status & Worktree Capture

    /// Captures branch, ahead/behind, worktree status, and dirty files for `projectPath`.
    /// Never blocks indefinitely (enforces `timeoutSeconds`) and returns a safe empty snapshot for non-git dirs.
    public static func captureGitStatus(
        projectPath: String,
        timeoutSeconds: Double = 3.0
    ) -> GitStatusSnapshot {
        let normalized = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
            .standardizedFileURL.path

        guard let porcelain = runGit(
            args: ["status", "--porcelain=v1", "--branch"],
            cwd: normalized,
            timeoutSeconds: timeoutSeconds
        ) else {
            return GitStatusSnapshot(projectPath: normalized, capturedAt: Date())
        }

        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var isDetachedHead = false
        var changes: [GitFileChange] = []

        for line in porcelain.components(separatedBy: .newlines) where !line.isEmpty {
            if line.hasPrefix("## ") {
                let parsed = parsePorcelainBranchHeader(String(line.dropFirst(3)))
                branch = parsed.branch
                upstream = parsed.upstream
                ahead = parsed.ahead
                behind = parsed.behind
                isDetachedHead = parsed.isDetached
                continue
            }

            if let change = parsePorcelainChangeLine(line) {
                changes.append(change)
            }
        }

        // Fallback branch check for repos with zero commits or detached HEAD
        if branch == nil {
            if let revBranch = runGit(
                args: ["rev-parse", "--abbrev-ref", "HEAD"],
                cwd: normalized,
                timeoutSeconds: timeoutSeconds
            )?.trimmingCharacters(in: .whitespacesAndNewlines), !revBranch.isEmpty {
                if revBranch == "HEAD" {
                    isDetachedHead = true
                } else {
                    branch = revBranch
                }
            }
        }

        // Also union with `git diff --name-only` in case of submodule/edge entries
        if let diffNames = runGit(
            args: ["diff", "--name-only"],
            cwd: normalized,
            timeoutSeconds: timeoutSeconds
        ) {
            var known = Set(changes.map(\.path))
            for rawPath in diffNames.components(separatedBy: .newlines) {
                let p = normalizeRelPath(rawPath.trimmingCharacters(in: .whitespacesAndNewlines))
                guard !p.isEmpty, known.insert(p).inserted else { continue }
                changes.append(GitFileChange(path: p, kind: .modified, isStaged: false, isUnstaged: true))
            }
        }

        let (isWorktree, worktreePath) = detectWorktree(projectPath: normalized, timeoutSeconds: timeoutSeconds)

        return GitStatusSnapshot(
            projectPath: normalized,
            branch: branch,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            isDetachedHead: isDetachedHead,
            isWorktree: isWorktree,
            worktreePath: worktreePath,
            changes: changes,
            capturedAt: Date()
        )
    }

    /// Runs full git + spec governance analysis, identifying modified files with zero matching spec coverage.
    public static func analyzeGovernance(
        projectPath: String,
        referencedSpecPaths: [String] = [],
        timeoutSeconds: Double = 3.0
    ) -> SpecGovernanceReport {
        let gitStatus = captureGitStatus(projectPath: projectPath, timeoutSeconds: timeoutSeconds)
        let specs = scanSpecs(
            projectPath: projectPath,
            modifiedFiles: gitStatus.modifiedPaths,
            referencedSpecPaths: referencedSpecPaths
        )

        var covered = Set<String>()
        for spec in specs {
            for path in spec.matchedModifiedFiles {
                covered.insert(path)
            }
        }

        let uncovered = gitStatus.modifiedPaths.filter { path in
            let norm = normalizeRelPath(path)
            if norm.hasPrefix(".trellis/") { return false }
            return !covered.contains(norm)
        }

        return SpecGovernanceReport(
            specs: specs,
            gitStatus: gitStatus,
            uncoveredModifiedFiles: uncovered
        )
    }

    // MARK: - Private Helpers

    private static func evaluateSpecHealth(content: String) -> (lineCount: Int, isEmptyTemplate: Bool) {
        let lines = content.components(separatedBy: .newlines)
        var inHtmlComment = false
        var inFrontmatter = false
        var sawPlaceholder = false
        var substantiveLines = 0
        var nonEmptyLines = 0

        for (idx, rawLine) in lines.enumerated() {
            let t = rawLine.trimmingCharacters(in: .whitespaces)
            if idx == 0 && t == "---" {
                inFrontmatter = true
                continue
            }
            if inFrontmatter {
                if t == "---" || t == "..." { inFrontmatter = false }
                continue
            }

            if t.isEmpty { continue }
            nonEmptyLines += 1

            if t.contains("<!--") { inHtmlComment = true }
            if inHtmlComment {
                if t.contains("-->") { inHtmlComment = false }
                continue
            }

            let lower = t.lowercased()
            if lower.contains("(to be filled")
                || lower.contains("to be filled by the team")
                || lower.contains("| to fill |")
                || lower.hasSuffix("| to fill")
            {
                sawPlaceholder = true
                continue
            }

            if t.hasPrefix("#") || t == "---" || t.hasPrefix(">") {
                continue
            }

            substantiveLines += 1
        }

        let isEmpty = (sawPlaceholder && substantiveLines < 12) || substantiveLines < 5
        return (nonEmptyLines, isEmpty)
    }

    private static func globToRegex(_ pattern: String) -> String {
        var regex = "^"
        let chars = Array(pattern)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    // Handle `**/` matching zero or more directory levels
                    if i + 2 < chars.count && chars[i + 2] == "/" {
                        regex += "(?:.*/)?"
                        i += 3
                    } else {
                        regex += ".*"
                        i += 2
                    }
                } else {
                    regex += "[^/]*"
                    i += 1
                }
            } else if c == "?" {
                regex += "[^/]"
                i += 1
            } else if ".+^${}()|[]\\".contains(c) {
                regex += "\\\(c)"
                i += 1
            } else {
                regex.append(c)
                i += 1
            }
        }

        regex += "$"
        return regex
    }

    private static func normalizeRelPath(_ path: String) -> String {
        var norm = path.replacingOccurrences(of: "\\", with: "/")
        while norm.hasPrefix("./") {
            norm = String(norm.dropFirst(2))
        }
        return norm
    }

    private static func parsePorcelainBranchHeader(_ header: String) -> (
        branch: String?,
        upstream: String?,
        ahead: Int,
        behind: Int,
        isDetached: Bool
    ) {
        if header.hasPrefix("HEAD (no branch)") || header.hasPrefix("HEAD (detached") {
            return (nil, nil, 0, 0, true)
        }
        if header.hasPrefix("No commits yet on ") {
            let name = String(header.dropFirst("No commits yet on ".count)).trimmingCharacters(in: .whitespaces)
            return (name.isEmpty ? nil : name, nil, 0, 0, false)
        }

        var ahead = 0
        var behind = 0
        var core = header

        if let bracketOpen = header.lastIndex(of: "["), let bracketClose = header.lastIndex(of: "]"),
           bracketOpen < bracketClose
        {
            let inside = String(header[header.index(after: bracketOpen)..<bracketClose])
            core = String(header[..<bracketOpen]).trimmingCharacters(in: .whitespaces)
            for part in inside.split(separator: ",") {
                let item = part.trimmingCharacters(in: .whitespaces)
                if item.hasPrefix("ahead "), let n = Int(item.dropFirst(6)) {
                    ahead = n
                } else if item.hasPrefix("behind "), let n = Int(item.dropFirst(7)) {
                    behind = n
                }
            }
        }

        if let dots = core.range(of: "...") {
            let branch = String(core[..<dots.lowerBound]).trimmingCharacters(in: .whitespaces)
            let upstream = String(core[dots.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (branch.isEmpty ? nil : branch, upstream.isEmpty ? nil : upstream, ahead, behind, false)
        }

        let trimmed = core.trimmingCharacters(in: .whitespaces)
        return (trimmed.isEmpty ? nil : trimmed, nil, ahead, behind, false)
    }

    private static func parsePorcelainChangeLine(_ line: String) -> GitFileChange? {
        guard line.count >= 4 else { return nil }
        let idx0 = line.startIndex
        let idx1 = line.index(after: idx0)
        let idx2 = line.index(after: idx1)
        let idx3 = line.index(after: idx2)

        let x = line[idx0]
        let y = line[idx1]
        let rawPath = unquoteGitPath(String(line[idx3...]).trimmingCharacters(in: .whitespaces))
        guard !rawPath.isEmpty else { return nil }

        if x == "?" && y == "?" {
            return GitFileChange(path: normalizeRelPath(rawPath), kind: .untracked, isStaged: false, isUnstaged: true)
        }
        if x == "!" && y == "!" {
            return nil
        }

        var finalPath = rawPath
        var originalPath: String?
        if let arrow = rawPath.range(of: " -> ") {
            originalPath = normalizeRelPath(unquoteGitPath(String(rawPath[..<arrow.lowerBound])))
            finalPath = normalizeRelPath(unquoteGitPath(String(rawPath[arrow.upperBound...])))
        } else {
            finalPath = normalizeRelPath(rawPath)
        }

        let isStaged = x != " " && x != "?"
        let isUnstaged = y != " " && y != "?"
        let kind: GitChangeKind
        if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
            kind = .conflicted
        } else if x == "R" || y == "R" || originalPath != nil {
            kind = .renamed
        } else if x == "D" || y == "D" {
            kind = .deleted
        } else if x == "A" || y == "A" {
            kind = .added
        } else {
            kind = .modified
        }

        return GitFileChange(
            path: finalPath,
            originalPath: originalPath,
            kind: kind,
            isStaged: isStaged,
            isUnstaged: isUnstaged
        )
    }

    private static func unquoteGitPath(_ path: String) -> String {
        guard path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") else { return path }
        return String(path.dropFirst().dropLast())
    }

    private static func detectWorktree(projectPath: String, timeoutSeconds: Double) -> (Bool, String?) {
        // Fast filesystem check: linked git worktrees have a `.git` FILE (containing `gitdir: ...`) instead of a directory.
        let dotGit = (projectPath as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir), !isDir.boolValue {
            return (true, projectPath)
        }

        guard let out = runGit(
            args: ["rev-parse", "--git-dir", "--git-common-dir"],
            cwd: projectPath,
            timeoutSeconds: timeoutSeconds
        ) else {
            return (false, nil)
        }
        let lines = out.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2 else { return (false, nil) }
        let gitDir = URL(fileURLWithPath: lines[0], relativeTo: URL(fileURLWithPath: projectPath)).standardizedFileURL.path
        let commonDir = URL(fileURLWithPath: lines[1], relativeTo: URL(fileURLWithPath: projectPath)).standardizedFileURL.path
        if gitDir != commonDir {
            return (true, projectPath)
        }
        return (false, nil)
    }

    private static func runGit(args: [String], cwd: String, timeoutSeconds: Double) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        let waitResult = semaphore.wait(timeout: .now() + timeoutSeconds)
        if waitResult == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.5)
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
