import Foundation
@testable import TrellisCore

#if canImport(Testing)
import Testing
#endif

/// Standalone test suite runnable via both `swift test` (Swift Testing) and direct `swiftc` harnesses.
public enum TrellisCoreTestRunner {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw Failure(message: message)
        }
    }

    public static func testTaskRecordDecodesCanonicalAndLegacySubtasks() throws {
        let canonicalJSON = """
        {
          "id": "11-05-demo",
          "name": "11-05-demo",
          "title": "Canonical v0.7 Task",
          "description": "Tests string[] subtasks",
          "status": "in_progress",
          "priority": "P1",
          "branch": "feat/demo",
          "base_branch": "main",
          "worktree_path": "/tmp/wt-demo",
          "commit": "abc1234",
          "pr_url": "https://github.com/org/repo/pull/42",
          "subtasks": ["Step A", "Step B"],
          "children": ["11-05-child"],
          "parent": null,
          "relatedFiles": ["Sources/App.swift"],
          "notes": "Ship cleanly",
          "meta": { "tickets": 2 },
          "workflow": "custom-tdd"
        }
        """
        let canonical = try JSONDecoder().decode(TaskRecord.self, from: Data(canonicalJSON.utf8))
        try expect(canonical.subtasks.count == 2, "Expected 2 canonical subtasks")
        try expect(canonical.subtasks[0].name == "Step A", "Expected canonical subtask name Step A")
        try expect(canonical.subtasks[0].status == nil, "Canonical string subtask should have nil status")
        try expect(canonical.worktreePath == "/tmp/wt-demo", "Expected worktreePath")
        try expect(canonical.prUrl == "https://github.com/org/repo/pull/42", "Expected prUrl")
        try expect(canonical.workflow == "custom-tdd", "Expected workflow")

        let legacyJSON = """
        {
          "id": "01-legacy",
          "title": "Legacy Task",
          "status": "in_progress",
          "subtasks": [
            {"name": "Done step", "status": "completed"},
            {"name": "Open step", "status": "pending"}
          ]
        }
        """
        let legacy = try JSONDecoder().decode(TaskRecord.self, from: Data(legacyJSON.utf8))
        try expect(legacy.subtasks.count == 2, "Expected 2 legacy subtasks")
        try expect(legacy.subtasks[0].isCompleted == true, "Expected legacy subtask 0 completed")
        try expect(legacy.subtasks[1].isCompleted == false, "Expected legacy subtask 1 pending")
    }

    public static func testAppLanguageConfigTolerantDecode() throws {
        let missingLangJSON = #"{"roots":["/tmp/a"],"initialized":true}"#
        let decodedDefault = try JSONDecoder().decode(HUDConfig.self, from: Data(missingLangJSON.utf8))
        try expect(decodedDefault.language == .system, "Missing language field should default to .system")

        let zhJSON = #"{"language":"zh-Hans"}"#
        let decodedZh = try JSONDecoder().decode(HUDConfig.self, from: Data(zhJSON.utf8))
        try expect(decodedZh.language == .zhHans, "Expected .zhHans language")

        let enJSON = #"{"language":"en"}"#
        let decodedEn = try JSONDecoder().decode(HUDConfig.self, from: Data(enJSON.utf8))
        try expect(decodedEn.language == .en, "Expected .en language")
    }

    public static func testMarkdownChecklistParserHandlesSectionsCodeFencesAndACs() throws {
        let md = """
        # Implementation Plan

        ## 1. Core Parser
        - [x] 1.1 Parse checkboxes
        - [X] 1.2 Preserve sections
        * [ ] 1.3 Handle edge cases

        ```markdown
        - [x] This is inside a code fence and must be ignored
        ```

        ## Acceptance Criteria
        - [x] AC1 Unit tests pass
        - [ ] AC2 Zero warnings
        """

        let items = MarkdownChecklistParser.parseChecklists(markdown: md, sourceFile: "implement.md")
        try expect(items.count == 5, "Expected 5 checklist items, got \(items.count)")
        try expect(items[0].section == "1. Core Parser", "Expected section 1. Core Parser")
        try expect(items[0].isCompleted == true, "Item 0 completed")
        try expect(items[1].isCompleted == true, "Item 1 completed")
        try expect(items[2].isCompleted == false, "Item 2 incomplete")
        try expect(items[3].section == "Acceptance Criteria", "Expected AC section")
        try expect(items[3].text == "AC1 Unit tests pass", "Expected AC1 text")
        try expect(items[4].isCompleted == false, "Item 4 incomplete")
    }

    public static func testFrontmatterPathExtractorParsesBlockFlowAndBraceGlobs() throws {
        let blockSpec = """
        ---
        name: cli-backend
        paths:
          - packages/cli/src/**
          - "Sources/TrellisCore/*.swift" # inline comment
        ---
        # Guidelines
        """
        try expect(
            MarkdownChecklistParser.extractFrontmatterPaths(markdown: blockSpec)
                == ["packages/cli/src/**", "Sources/TrellisCore/*.swift"],
            "Block frontmatter paths mismatch"
        )

        let flowSpec = """
        ---
        paths: [src/**/*.{ts,tsx}, 'test/*.test.js', "docs/{api,guides}/**.md"]
        ---
        # Content
        """
        let extracted = MarkdownChecklistParser.extractFrontmatterPaths(markdown: flowSpec)
        try expect(
            extracted == ["src/**/*.{ts,tsx}", "test/*.test.js", "docs/{api,guides}/**.md"],
            "Brace glob flow frontmatter paths mismatch: \(extracted)"
        )
        try expect(
            SpecAndGitAnalyzer.matchesGlob(pattern: "src/**/*.{ts,tsx}", path: "src/components/Button.tsx"),
            "Brace glob should match .tsx"
        )
        try expect(
            SpecAndGitAnalyzer.matchesGlob(pattern: "src/**/*.{ts,tsx}", path: "src/index.ts"),
            "Brace glob should match .ts"
        )
        try expect(
            !SpecAndGitAnalyzer.matchesGlob(pattern: "src/**/*.{ts,tsx}", path: "src/index.js"),
            "Brace glob should not match .js"
        )
    }

    public static func testProjectScannerDiscoversTasksSymlinkGuardAndTaskDirectoryPath() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("trellis-hud-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let repo = tmp.appendingPathComponent("demo-repo", isDirectory: true)
        let activeTask = repo.appendingPathComponent(".trellis/tasks/11-27-build-hud", isDirectory: true)
        let archivedTask = repo.appendingPathComponent(".trellis/tasks/archive/2026-11/11-01-old", isDirectory: true)
        let bootstrapTask = repo.appendingPathComponent(".trellis/tasks/00-bootstrap-guidelines", isDirectory: true)
        let outsideSecret = tmp.appendingPathComponent("secret.txt")

        try FileManager.default.createDirectory(at: activeTask.appendingPathComponent("research"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedTask, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bootstrapTask, withIntermediateDirectories: true)
        try "TOP_SECRET_DATA".write(to: outsideSecret, atomically: true, encoding: .utf8)

        // Create a symlink inside activeTask pointing outside activeTask (must be blocked by loadTaskDocument).
        let escapeSymlink = activeTask.appendingPathComponent("escape.md")
        try FileManager.default.createSymbolicLink(at: escapeSymlink, withDestinationURL: outsideSecret)

        try """
        {"id":"build-hud","title":"Build HUD","status":"in_progress","priority":"P0","subtasks":["Phase A"]}
        """.write(to: activeTask.appendingPathComponent("task.json"), atomically: true, encoding: .utf8)

        try """
        # Build HUD

        - Status: in_progress

        Build a crisp native Swift HUD with real checklists.

        ## Acceptance Criteria
        - [x] AC1 Compiles cleanly
        - [ ] AC2 Ships bundle
        """.write(to: activeTask.appendingPathComponent("prd.md"), atomically: true, encoding: .utf8)

        try """
        ## Steps
        - [x] Step 1
        - [x] Step 2
        - [ ] Step 3
        """.write(to: activeTask.appendingPathComponent("implement.md"), atomically: true, encoding: .utf8)

        try """
        {"_example": "seed line"}
        {"file": ".trellis/spec/cli/backend/rules.md", "reason": "Follow backend rules"}
        """.write(to: activeTask.appendingPathComponent("implement.jsonl"), atomically: true, encoding: .utf8)

        try """
        {"id":"old","title":"Archived Task","status":"completed"}
        """.write(to: archivedTask.appendingPathComponent("task.json"), atomically: true, encoding: .utf8)

        try """
        {"id":"00-bootstrap-guidelines","title":"Bootstrap","status":"in_progress"}
        """.write(to: bootstrapTask.appendingPathComponent("task.json"), atomically: true, encoding: .utf8)

        let discovered = ProjectScanner.discoverProjects(roots: [tmp.path], maxDepth: 3)
        try expect(discovered.count == 1, "Expected 1 discovered project")
        try expect(discovered[0].name == "demo-repo", "Expected demo-repo")
        try expect(discovered[0].activeTaskCount == 1, "Expected 1 active task")
        try expect(discovered[0].archivedTaskCount == 1, "Expected 1 archived task")

        let active = ProjectScanner.scanActiveTasks(projectPath: repo.path)
        try expect(active.count == 1, "Expected 1 active task snapshot")
        let task = active[0]
        try expect(task.phase == .implement, "Expected implement phase")
        try expect(task.completedChecklistCount == 3, "Expected 3 completed checklist items")
        try expect(task.totalChecklistCount == 5, "Expected 5 total checklist items")
        try expect(abs(task.progress - 0.6) < 0.001, "Expected 0.6 honest progress")
        try expect(task.artifacts.implContextCount == 1, "Expected 1 real impl context entry")
        try expect(task.excerpt.contains("Build a crisp native Swift HUD"), "Expected PRD excerpt")
        try expect(
            task.taskDirectoryPath == ConfigStore.normalizePath(activeTask.path),
            "Active TaskSnapshot.taskDirectoryPath mismatch: \(task.taskDirectoryPath)"
        )

        // Safe document loader allows internal files and rejects traversal AND escaping symlinks
        try expect(ProjectScanner.loadTaskDocument(taskDir: activeTask.path, relativePath: "prd.md") != nil, "Load prd.md")
        try expect(ProjectScanner.loadTaskDocument(taskDir: activeTask.path, relativePath: "../task.json") == nil, "Reject .. traversal")
        try expect(ProjectScanner.loadTaskDocument(taskDir: activeTask.path, relativePath: "/etc/passwd") == nil, "Reject absolute path")
        try expect(ProjectScanner.loadTaskDocument(taskDir: activeTask.path, relativePath: "escape.md") == nil, "Reject symlink escaping taskDir")

        let archived = ProjectScanner.scanArchivedTasks(projectPath: repo.path)
        try expect(archived.count == 1, "Expected 1 archived task")
        try expect(archived[0].archived == true, "Archived flag true")
        try expect(archived[0].phase == .archive, "Archived phase")
        try expect(archived[0].dir == "archive/2026-11/11-01-old", "Archived relative dir")
        try expect(
            archived[0].taskDirectoryPath == ConfigStore.normalizePath(archivedTask.path),
            "Archived TaskSnapshot.taskDirectoryPath mismatch: \(archived[0].taskDirectoryPath)"
        )
    }

    public static func testSpecAnalyzerHandlesThreeLevelMonorepoGlobAndCJKGitPaths() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("trellis-hud-spec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let backendDir = tmp.appendingPathComponent(".trellis/spec/cli/backend", isDirectory: true)
        let frontendDir = tmp.appendingPathComponent(".trellis/spec/frontend", isDirectory: true)
        try FileManager.default.createDirectory(at: backendDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frontendDir, withIntermediateDirectories: true)

        try """
        ---
        paths:
          - packages/cli/src/**/*.ts
          - Sources/TrellisCore/Scanner/*.swift
        ---
        # CLI Backend Rules
        Rule 1: Always validate inputs.
        Rule 2: Keep pure reducers deterministic.
        Rule 3: Never swallow IO errors silently.
        Rule 4: Return Sendable structs across boundaries.
        Rule 5: Guard path traversal on all file reads.
        """.write(to: backendDir.appendingPathComponent("rules.md"), atomically: true, encoding: .utf8)

        try """
        # Component Guidelines

        <!-- Fill me -->

        (To be filled by the team)
        """.write(to: frontendDir.appendingPathComponent("component-guidelines.md"), atomically: true, encoding: .utf8)

        let modified = [
            "packages/cli/src/commands/mem.ts",
            "Sources/TrellisCore/Scanner/ProjectScanner.swift",
            "README.md",
        ]
        let specs = SpecAndGitAnalyzer.scanSpecs(
            projectPath: tmp.path,
            modifiedFiles: modified,
            referencedSpecPaths: [".trellis/spec/cli/backend/rules.md"]
        )

        try expect(specs.count == 2, "Expected 2 specs")
        guard let cliSpec = specs.first(where: { $0.relativePath == ".trellis/spec/cli/backend/rules.md" }) else {
            throw Failure(message: "Missing 3-level cliSpec")
        }
        try expect(cliSpec.packageName == "cli", "Expected packageName cli")
        try expect(cliSpec.layer == "backend", "Expected layer backend")
        try expect(cliSpec.isEmptyTemplate == false, "cliSpec should not be empty template")
        try expect(cliSpec.referencedByTaskCount == 1, "Expected 1 ref")
        try expect(
            cliSpec.matchedModifiedFiles == ["packages/cli/src/commands/mem.ts", "Sources/TrellisCore/Scanner/ProjectScanner.swift"],
            "Unexpected matchedModifiedFiles"
        )

        guard let emptySpec = specs.first(where: { $0.name == "component-guidelines" }) else {
            throw Failure(message: "Missing 2-level emptySpec")
        }
        try expect(emptySpec.packageName == nil, "2-level spec should have nil packageName")
        try expect(emptySpec.layer == "frontend", "2-level spec should have layer frontend")
        try expect(emptySpec.isEmptyTemplate == true, "Placeholder spec should be empty template")

        // Verify CJK UTF-8 git paths are NOT octal-escaped (`-c core.quotepath=false`)
        let initRes = SubprocessRunner.run(executable: "/usr/bin/git", arguments: ["init"], currentDirectory: tmp.path)
        if initRes.succeeded {
            let docsDir = tmp.appendingPathComponent("文档", isDirectory: true)
            try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
            try "中文测试".write(to: docsDir.appendingPathComponent("设计说明.md"), atomically: true, encoding: .utf8)
            let status = SpecAndGitAnalyzer.captureGitStatus(projectPath: tmp.path)
            let hasUnescapedCJK = status.modifiedPaths.contains { $0.contains("文档") }
            try expect(hasUnescapedCJK, "Expected unescaped CJK path in git status, got \(status.modifiedPaths)")
        }
    }

    public static func testChannelReaderReducesWorkersThreadsBroadcastAndPendingMessages() throws {
        let jsonl = """
        {"seq":1,"ts":"2026-11-27T07:00:00Z","kind":"create","by":"main","type":"forum","description":"Review swarm","cwd":"/repo/demo","task":"11-27-demo"}
        {"seq":2,"ts":"2026-11-27T07:00:01Z","kind":"channel","by":"main","action":"title","title":"HUD Review"}
        {"seq":3,"ts":"2026-11-27T07:00:02Z","kind":"spawned","by":"main","as":"reviewer","provider":"codex","agent":"trellis-check","inboxPolicy":"explicitOnly"}
        {"seq":4,"ts":"2026-11-27T07:00:02.500Z","kind":"spawned","by":"main","as":"watcher","provider":"claude","inboxPolicy":"broadcastAndExplicit"}
        {"seq":5,"ts":"2026-11-27T07:00:03Z","kind":"message","by":"main","to":"reviewer","text":"Please audit Scanner"}
        {"seq":6,"ts":"2026-11-27T07:00:04Z","kind":"turn_started","by":"supervisor:reviewer","worker":"reviewer","turnId":"t1","inputSeq":5}
        {"seq":7,"ts":"2026-11-27T07:00:05Z","kind":"message","by":"main","to":"reviewer","text":"Also check glob matching"}
        {"seq":8,"ts":"2026-11-27T07:00:05Z","kind":"message","by":"main","text":"Broadcast update for all"}
        {"seq":9,"ts":"2026-11-27T07:00:05Z","kind":"message","by":"watcher","text":"Watcher self-broadcast must not count"}
        {"seq":10,"ts":"2026-11-27T07:00:06Z","kind":"thread","by":"main","action":"opened","thread":"t-old","title":"Glob edge cases","labels":["scanner"]}
        {"seq":11,"ts":"2026-11-27T07:00:07Z","kind":"thread","by":"reviewer","action":"comment","thread":"t-old","text":"Looks solid!"}
        {"seq":12,"ts":"2026-11-27T07:00:08Z","kind":"thread","by":"main","action":"rename","thread":"t-old","newThread":"t-glob"}
        {corrupted json line should be skipped gracefully
        """

        let info = ChannelReader.parseChannelEvents(
            jsonlContent: jsonl,
            name: "review",
            scope: .project,
            projectKey: "-repo-demo",
            dirPath: "/tmp/channels/-repo-demo/review"
        )

        try expect(info.type == .forum, "Expected forum channel")
        try expect(info.title == "HUD Review", "Expected channel title")
        try expect(info.taskRef == "11-27-demo", "Expected taskRef")
        try expect(info.lastSeq == 12, "Expected lastSeq 12")
        try expect(info.workers.count == 2, "Expected 2 workers")

        guard let reviewer = info.workers.first(where: { $0.workerId == "reviewer" }),
              let watcher = info.workers.first(where: { $0.workerId == "watcher" })
        else {
            throw Failure(message: "Missing expected workers")
        }

        try expect(reviewer.lifecycle == .running, "Expected running reviewer")
        try expect(reviewer.activity == .midTurn, "Expected midTurn reviewer")
        try expect(reviewer.pendingMessageCount == 1, "Expected 1 explicit pending message for reviewer, got \(reviewer.pendingMessageCount)")
        try expect(watcher.pendingMessageCount == 1, "Expected 1 broadcast pending message for watcher (excluding self), got \(watcher.pendingMessageCount)")

        try expect(info.threads.count == 1, "Expected 1 thread")
        try expect(info.threads[0].thread == "t-glob", "Expected renamed thread key")
        try expect(info.threads[0].aliases == ["t-old"], "Expected alias t-old")
        try expect(info.threads[0].comments == 1, "Expected 1 comment")
        try expect(info.recentMessages.count >= 4, "Expected >=4 recent messages")
    }

    public static func testMemoryReaderScansJournalsAndSearchesAntigravitySessions() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("trellis-hud-mem-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let devDir = tmp.appendingPathComponent("repo/.trellis/workspace/alice", isDirectory: true)
        try FileManager.default.createDirectory(at: devDir, withIntermediateDirectories: true)

        try """
        # Journal - alice

        ## Session 1: Initial Setup
        Bootstrapped repo.

        ## Session 2: Swift Scanner Implementation
        Implemented ProjectScanner, ChannelReader, and glob matching.
        """.write(to: devDir.appendingPathComponent("journal-1.md"), atomically: true, encoding: .utf8)

        let journals = MemoryReader.scanJournals(projectPath: tmp.appendingPathComponent("repo").path)
        try expect(journals.count == 1, "Expected 1 journal")
        try expect(journals[0].developer == "alice", "Expected developer alice")
        try expect(journals[0].indexNumber == 1, "Expected indexNumber 1")
        try expect(journals[0].latestHeading == "Session 2: Swift Scanner Implementation", "Expected latestHeading")
        try expect(journals[0].preview.contains("ProjectScanner"), "Expected preview text")

        let fakeHome = tmp.appendingPathComponent("home", isDirectory: true)
        let logDir = fakeHome.appendingPathComponent(".gemini/antigravity/brain/conv-123/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let repoPath = ConfigStore.normalizePath(tmp.appendingPathComponent("repo").path)
        try """
        {"type":"USER_INPUT","created_at":"2026-11-27T07:00:00Z","cwd":"\(repoPath)","content":"<USER_REQUEST>Design the Trellis Swift HUD notch controller</USER_REQUEST>"}
        {"type":"PLANNER_RESPONSE","created_at":"2026-11-27T07:00:05Z","content":"Using NSPanel with safeAreaInsets for native notch alignment."}
        """.write(to: logDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        let found = MemoryReader.searchMemory(
            query: "notch NSPanel",
            projectPath: repoPath,
            limit: 10,
            homeDirectory: fakeHome.path,
            preferCLI: false
        )
        try expect(found.count == 1, "Expected 1 matching Antigravity session")
        try expect(found[0].platform == .antigravity, "Expected antigravity platform")
        try expect(found[0].title == "Design the Trellis Swift HUD notch controller", "Expected session title")
        try expect(found[0].matchCount >= 2, "Expected >=2 token matches")
    }

    public static func testHookEventParserTimestampsAndArchiveSkip() throws {
        // Archive path must not resolve "archive" as an active task id
        try expect(
            HookEventParser.extractTaskDir(from: "cat /repo/.trellis/tasks/archive/2026-11/old/prd.md") == nil,
            "extractTaskDir must skip 'archive' segment"
        )
        try expect(
            HookEventParser.extractTaskDir(from: "edit /repo/.trellis/tasks/11-27-live/prd.md") == "11-27-live",
            "extractTaskDir should extract active task dir"
        )

        // Millisecond timestamp in hook payload should normalize to Unix seconds
        let payload = """
        {
          "session_id": "s-ms",
          "cwd": "/tmp/demo",
          "event_name": "PreToolUse",
          "tool_name": "Read",
          "timestamp": 1732690000123
        }
        """
        let event = try HookEventParser.parsePayload(
            payload,
            overrides: HookOverrides(agent: "claude")
        )
        try expect(event.timestamp == 1_732_690_000, "Expected ms timestamp normalized to seconds, got \(event.timestamp)")
    }

    public static func testSubprocessRunnerLargeOutputDoesNotDeadlock() throws {
        // Emit >128 KB to stdout AND >128 KB to stderr simultaneously to prove pipe draining never deadlocks.
        let result = SubprocessRunner.run(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import sys; sys.stdout.write('A'*140000); sys.stderr.write('B'*140000)"],
            timeoutSeconds: 5.0,
            maxOutputBytes: 200_000
        )
        try expect(result.succeeded, "SubprocessRunner large output failed or timed out: timedOut=\(result.timedOut) code=\(result.exitCode)")
        try expect(result.stdout.count == 140_000, "Expected 140000 stdout bytes, got \(result.stdout.count)")
        try expect(result.stderr.count == 140_000, "Expected 140000 stderr bytes, got \(result.stderr.count)")
    }

    public static func runAll() throws {
        try testTaskRecordDecodesCanonicalAndLegacySubtasks()
        try testAppLanguageConfigTolerantDecode()
        try testMarkdownChecklistParserHandlesSectionsCodeFencesAndACs()
        try testFrontmatterPathExtractorParsesBlockFlowAndBraceGlobs()
        try testProjectScannerDiscoversTasksSymlinkGuardAndTaskDirectoryPath()
        try testSpecAnalyzerHandlesThreeLevelMonorepoGlobAndCJKGitPaths()
        try testChannelReaderReducesWorkersThreadsBroadcastAndPendingMessages()
        try testMemoryReaderScansJournalsAndSearchesAntigravitySessions()
        try testHookEventParserTimestampsAndArchiveSkip()
        try testSubprocessRunnerLargeOutputDoesNotDeadlock()
    }
}

#if canImport(Testing)
@Test func taskRecordDecodesCanonicalAndLegacySubtasks() throws {
    try TrellisCoreTestRunner.testTaskRecordDecodesCanonicalAndLegacySubtasks()
}

@Test func appLanguageConfigTolerantDecode() throws {
    try TrellisCoreTestRunner.testAppLanguageConfigTolerantDecode()
}

@Test func markdownChecklistParserHandlesSectionsCodeFencesAndACs() throws {
    try TrellisCoreTestRunner.testMarkdownChecklistParserHandlesSectionsCodeFencesAndACs()
}

@Test func frontmatterPathExtractorParsesBlockFlowAndBraceGlobs() throws {
    try TrellisCoreTestRunner.testFrontmatterPathExtractorParsesBlockFlowAndBraceGlobs()
}

@Test func projectScannerDiscoversTasksSymlinkGuardAndTaskDirectoryPath() throws {
    try TrellisCoreTestRunner.testProjectScannerDiscoversTasksSymlinkGuardAndTaskDirectoryPath()
}

@Test func specAnalyzerHandlesThreeLevelMonorepoGlobAndCJKGitPaths() throws {
    try TrellisCoreTestRunner.testSpecAnalyzerHandlesThreeLevelMonorepoGlobAndCJKGitPaths()
}

@Test func channelReaderReducesWorkersThreadsBroadcastAndPendingMessages() throws {
    try TrellisCoreTestRunner.testChannelReaderReducesWorkersThreadsBroadcastAndPendingMessages()
}

@Test func memoryReaderScansJournalsAndSearchesAntigravitySessions() throws {
    try TrellisCoreTestRunner.testMemoryReaderScansJournalsAndSearchesAntigravitySessions()
}

@Test func hookEventParserTimestampsAndArchiveSkip() throws {
    try TrellisCoreTestRunner.testHookEventParserTimestampsAndArchiveSkip()
}

@Test func subprocessRunnerLargeOutputDoesNotDeadlock() throws {
    try TrellisCoreTestRunner.testSubprocessRunnerLargeOutputDoesNotDeadlock()
}
#endif
