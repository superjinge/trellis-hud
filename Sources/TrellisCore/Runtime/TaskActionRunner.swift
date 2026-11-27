import Foundation
import os

/// Runs Trellis task lifecycle scripts (`validate`, `start`, `archive`) and channel commands asynchronously
/// without blocking the main thread, handling macOS `.app` minimal `PATH`, cached Python probing, ANSI stripping,
/// concurrent pipe draining (`SubprocessRunner`), and backward-compatible archive flags.
public struct TaskActionRunner: Sendable {
    public static let archiveFlagProfiles: [[String]] = [
        ["--no-commit", "--skip-branch-validation"],
        ["--no-commit"],
        [],
    ]

    private static let cachedPythonLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    public init() {}

    // MARK: - Pure Validation & Formatting Helpers

    public static func validateActiveTaskName(_ taskDir: String) throws {
        let trimmed = taskDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty
            || trimmed != taskDir
            || trimmed == "."
            || trimmed == ".."
            || trimmed.contains("/")
            || trimmed.contains("\\")
            || trimmed.hasPrefix("archive") {
            throw NSError(domain: "TaskActionRunner", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid active task directory name: \(taskDir)",
            ])
        }
    }

    public static func stripANSI(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        let scalars = Array(input.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i].value == 0x1B, i + 1 < scalars.count, scalars[i + 1] == "[" {
                i += 2
                while i < scalars.count {
                    let v = scalars[i].value
                    i += 1
                    if v >= 0x40 && v <= 0x7E {
                        break
                    }
                }
                continue
            }
            result.unicodeScalars.append(scalars[i])
            i += 1
        }
        return result
    }

    public static func ensurePathEntries(
        currentPath: String?,
        required: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]
    ) -> String {
        var entries = (currentPath ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        for dir in required where !entries.contains(dir) {
            entries.append(dir)
        }
        return entries.joined(separator: ":")
    }

    public static func augmentedEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ensurePathEntries(
            currentPath: env["PATH"],
            required: ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        )
        return env
    }

    public static func isUnrecognizedArgumentsError(_ output: String) -> Bool {
        output.lowercased().contains("unrecognized arguments")
    }

    /// Resolves and caches a working Python 3 executable once per process.
    public static func resolvePythonCommand() -> String {
        if let cached = cachedPythonLock.withLock({ $0 }) {
            return cached
        }
        let env = augmentedEnvironment()
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        var resolved = "/usr/bin/python3"
        for path in candidates {
            if SubprocessRunner.probeExecutable(path, arguments: ["--version"], environment: env, timeoutSeconds: 3.0) {
                resolved = path
                break
            }
        }
        let finalResolved = resolved
        cachedPythonLock.withLock { $0 = finalResolved }
        return finalResolved
    }

    public static func resolveTrellisCLI() -> String? {
        let env = augmentedEnvironment()
        let pathDirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in pathDirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("trellis").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvmDir = URL(fileURLWithPath: home).appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvmDir, includingPropertiesForKeys: nil) {
            for versionDir in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                let candidate = versionDir.appendingPathComponent("bin/trellis").path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - Task Actions

    public func validateTask(projectPath: String, taskDir: String) async -> ActionResult {
        await runTaskScript(
            action: .validate,
            projectPath: projectPath,
            taskDir: taskDir,
            arguments: ["validate", taskDir]
        )
    }

    public func startTask(
        projectPath: String,
        taskDir: String,
        allowEmptyContext: Bool = false
    ) async -> ActionResult {
        var args = ["start", taskDir]
        if allowEmptyContext {
            args.append("--allow-empty-context")
        }
        return await runTaskScript(
            action: .start,
            projectPath: projectPath,
            taskDir: taskDir,
            arguments: args
        )
    }

    /// Archives an active task using `--no-commit --skip-branch-validation`, falling back cleanly on older `task.py`.
    public func archiveTask(projectPath: String, taskDir: String) async -> ActionResult {
        let start = Date()
        do {
            try Self.validateActiveTaskName(taskDir)
            let scriptPath = try locateTaskScript(projectPath: projectPath, taskDir: taskDir)
            let python = Self.resolvePythonCommand()
            let env = Self.augmentedEnvironment()

            return await Self.runArchiveWithFallback { flags in
                await Self.runProcess(
                    action: .archive,
                    executable: python,
                    arguments: [scriptPath, "archive", taskDir] + flags,
                    cwd: projectPath,
                    environment: env,
                    timeoutSeconds: 30.0
                )
            }
        } catch {
            return ActionResult(
                success: false,
                action: .archive,
                exitCode: 1,
                stderr: error.localizedDescription,
                message: error.localizedDescription,
                durationMs: Int(Date().timeIntervalSince(start) * 1000)
            )
        }
    }

    /// Pure fallback orchestrator (async, unit-testable).
    public static func runArchiveWithFallback(
        _ runner: @Sendable ([String]) async -> ActionResult
    ) async -> ActionResult {
        var lastResult = ActionResult(success: false, action: .archive, exitCode: 1, message: "Archive failed")
        for (idx, flags) in archiveFlagProfiles.enumerated() {
            let result = await runner(flags)
            if result.success {
                return result
            }
            lastResult = result
            let hasNext = idx + 1 < archiveFlagProfiles.count
            let combined = "\(result.stdout)\n\(result.stderr)\n\(result.message)"
            if hasNext && isUnrecognizedArgumentsError(combined) {
                continue
            }
            return result
        }
        return lastResult
    }

    // MARK: - Channel Worker Actions

    public func interruptWorker(projectPath: String, channel: String, worker: String) async -> ActionResult {
        guard let trellis = Self.resolveTrellisCLI() else {
            return ActionResult(success: false, action: .interruptWorker, exitCode: 127, message: "trellis CLI not found in PATH")
        }
        return await Self.runProcess(
            action: .interruptWorker,
            executable: trellis,
            arguments: ["channel", "interrupt", channel, worker],
            cwd: projectPath,
            environment: Self.augmentedEnvironment(),
            timeoutSeconds: 15.0
        )
    }

    public func killWorker(projectPath: String, channel: String, worker: String) async -> ActionResult {
        guard let trellis = Self.resolveTrellisCLI() else {
            return ActionResult(success: false, action: .killWorker, exitCode: 127, message: "trellis CLI not found in PATH")
        }
        return await Self.runProcess(
            action: .killWorker,
            executable: trellis,
            arguments: ["channel", "kill", channel, worker],
            cwd: projectPath,
            environment: Self.augmentedEnvironment(),
            timeoutSeconds: 15.0
        )
    }

    // MARK: - Subprocess Execution

    private func runTaskScript(
        action: ActionKind,
        projectPath: String,
        taskDir: String,
        arguments: [String]
    ) async -> ActionResult {
        do {
            try Self.validateActiveTaskName(taskDir)
            let scriptPath = try locateTaskScript(projectPath: projectPath, taskDir: taskDir)
            return await Self.runProcess(
                action: action,
                executable: Self.resolvePythonCommand(),
                arguments: [scriptPath] + arguments,
                cwd: projectPath,
                environment: Self.augmentedEnvironment(),
                timeoutSeconds: 30.0
            )
        } catch {
            return ActionResult(
                success: false,
                action: action,
                exitCode: 1,
                stderr: error.localizedDescription,
                message: error.localizedDescription
            )
        }
    }

    private func locateTaskScript(projectPath: String, taskDir: String) throws -> String {
        let fm = FileManager.default
        let projectURL = URL(fileURLWithPath: ConfigStore.expandHome(projectPath), isDirectory: true)
        let taskURL = projectURL.appendingPathComponent(".trellis/tasks/\(taskDir)", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: taskURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "TaskActionRunner", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Task directory not found: \(taskDir)",
            ])
        }
        let taskJSON = taskURL.appendingPathComponent("task.json")
        guard fm.fileExists(atPath: taskJSON.path) else {
            throw NSError(domain: "TaskActionRunner", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Task missing task.json: \(taskDir)",
            ])
        }
        let scriptURL = projectURL.appendingPathComponent(".trellis/scripts/task.py")
        guard fm.fileExists(atPath: scriptURL.path) else {
            throw NSError(domain: "TaskActionRunner", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Missing Trellis script: \(scriptURL.path)",
            ])
        }
        return scriptURL.path
    }

    private static func runProcess(
        action: ActionKind,
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String],
        timeoutSeconds: Double
    ) async -> ActionResult {
        let start = Date()
        let result = await SubprocessRunner.runAsync(
            executable: executable,
            arguments: arguments,
            currentDirectory: cwd,
            environment: environment,
            timeoutSeconds: timeoutSeconds
        )
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        let cleanOut = stripANSI(result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanErr = stripANSI(result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)

        let message: String
        if result.timedOut {
            message = "Timed out after \(Int(timeoutSeconds))s"
        } else {
            message = (cleanErr.isEmpty ? cleanOut : cleanErr)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? (result.succeeded ? "Completed" : "Exit status \(result.exitCode)")
        }

        return ActionResult(
            success: result.succeeded,
            action: action,
            exitCode: result.exitCode,
            stdout: cleanOut,
            stderr: cleanErr,
            message: message,
            durationMs: elapsedMs
        )
    }
}
