import Darwin
import Foundation

public struct SubprocessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var succeeded: Bool {
        !timedOut && exitCode == 0
    }

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Safe, deadlock-free subprocess execution utility.
/// Concurrently drains stdout & stderr pipes up to `maxOutputBytes` while enforcing
/// a wall-clock timeout with graceful `SIGTERM` -> `SIGKILL` escalation.
public enum SubprocessRunner: Sendable {
    public static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeoutSeconds: Double = 10.0,
        maxOutputBytes: Int = 2 * 1024 * 1024
    ) -> SubprocessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let currentDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: ConfigStore.expandHome(currentDirectory), isDirectory: true)
        }
        if let environment {
            proc.environment = environment
        }
        proc.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let exitSemaphore = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in
            exitSemaphore.signal()
        }

        do {
            try proc.run()
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            return SubprocessResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false
            )
        }

        // Close parent's write ends so EOF arrives cleanly as soon as the child exits.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        let outBox = LockedDataBox()
        let errBox = LockedDataBox()
        let drainGroup = DispatchGroup()
        let readQueue = DispatchQueue(label: "com.superjinge.trellis-hud.subprocess-drain", qos: .userInitiated, attributes: .concurrent)

        drainGroup.enter()
        readQueue.async {
            let data = readBounded(handle: outPipe.fileHandleForReading, maxBytes: maxOutputBytes)
            outBox.set(data)
            try? outPipe.fileHandleForReading.close()
            drainGroup.leave()
        }

        drainGroup.enter()
        readQueue.async {
            let data = readBounded(handle: errPipe.fileHandleForReading, maxBytes: maxOutputBytes)
            errBox.set(data)
            try? errPipe.fileHandleForReading.close()
            drainGroup.leave()
        }

        let effectiveTimeout = max(0.05, timeoutSeconds)
        let waitResult = exitSemaphore.wait(timeout: .now() + effectiveTimeout)
        var didTimeout = false

        if waitResult == .timedOut {
            didTimeout = true
            let pid = proc.processIdentifier
            if proc.isRunning {
                proc.terminate()
                if exitSemaphore.wait(timeout: .now() + 0.5) == .timedOut, proc.isRunning, pid > 0 {
                    _ = Darwin.kill(pid, SIGKILL)
                    _ = exitSemaphore.wait(timeout: .now() + 0.5)
                }
            }
        }

        // Wait briefly for concurrent pipe readers to finish after process exit/kill.
        _ = drainGroup.wait(timeout: .now() + 1.0)

        let stdoutStr = String(data: outBox.get(), encoding: .utf8) ?? ""
        let stderrStr = String(data: errBox.get(), encoding: .utf8) ?? ""
        let code: Int32 = didTimeout ? -1 : proc.terminationStatus

        return SubprocessResult(
            exitCode: code,
            stdout: stdoutStr,
            stderr: stderrStr,
            timedOut: didTimeout
        )
    }

    public static func runAsync(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeoutSeconds: Double = 10.0,
        maxOutputBytes: Int = 2 * 1024 * 1024
    ) async -> SubprocessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = run(
                    executable: executable,
                    arguments: arguments,
                    currentDirectory: currentDirectory,
                    environment: environment,
                    timeoutSeconds: timeoutSeconds,
                    maxOutputBytes: maxOutputBytes
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// Probes whether an executable exits with status 0, discarding output via `FileHandle.nullDevice`.
    public static func probeExecutable(
        _ path: String,
        arguments: [String] = ["--version"],
        environment: [String: String]? = nil,
        timeoutSeconds: Double = 3.0
    ) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        if let environment {
            proc.environment = environment
        }
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }

        do {
            try proc.run()
        } catch {
            return false
        }

        if sem.wait(timeout: .now() + max(0.05, timeoutSeconds)) == .timedOut {
            let pid = proc.processIdentifier
            if proc.isRunning {
                proc.terminate()
                if sem.wait(timeout: .now() + 0.3) == .timedOut, proc.isRunning, pid > 0 {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
            return false
        }
        return proc.terminationStatus == 0
    }

    private static func readBounded(handle: FileHandle, maxBytes: Int) -> Data {
        var collected = Data()
        let chunkSize = 16_384
        let fd = handle.fileDescriptor
        var buf = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = Darwin.read(fd, &buf, chunkSize)
            if n > 0 {
                if collected.count < maxBytes {
                    let remaining = maxBytes - collected.count
                    let toCopy = min(n, remaining)
                    collected.append(contentsOf: buf[0..<toCopy])
                }
                // Continue draining past maxBytes so the child process never blocks on a full pipe.
            } else if n == 0 {
                break
            } else {
                if errno == EINTR { continue }
                break
            }
        }
        return collected
    }
}

private final class LockedDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        let copy = data
        lock.unlock()
        return copy
    }
}
