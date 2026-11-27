import Darwin
import Foundation

/// Wire-compatible NDJSON Unix domain socket client + atomic inbox queue fallback.
/// Matches `trellis-card/src-tauri/src/ipc.rs`.
public enum UnixSocketProtocol {
    public static func encodeEvent(_ event: HookEvent) throws -> Data {
        let encoder = JSONEncoder()
        var data = try encoder.encode(event)
        data.append(0x0A) // '\n'
        return data
    }

    public static func decodeEvent(_ line: String) throws -> HookEvent {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid UTF-8 event line"))
        }
        return try JSONDecoder().decode(HookEvent.self, from: data)
    }

    /// Restricts a bound Unix domain socket to owner-only read/write (`0o600`).
    public static func setOwnerOnlyPermissions(socketPath: String) {
        _ = Darwin.chmod(socketPath, mode_t(0o600))
    }

    /// Atomically enqueues an event JSON file into the fallback inbox directory.
    @discardableResult
    public static func enqueue(_ event: HookEvent, queueDir: URL) -> Bool {
        guard let data = try? encodeEvent(event) else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: queueDir, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let nanos = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let pid = ProcessInfo.processInfo.processIdentifier
        let nonce = UInt32.random(in: 0...UInt32.max)
        let fileName = "\(nanos)-\(pid)-\(nonce).json"
        let targetURL = queueDir.appendingPathComponent(fileName, isDirectory: false)
        do {
            try data.write(to: targetURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Sends a hook event over the Unix domain socket, falling back to the inbox queue if unavailable.
    @discardableResult
    public static func sendEvent(
        _ event: HookEvent,
        socketPath: String? = nil,
        queueDir: URL? = nil
    ) -> Bool {
        let store = ConfigStore()
        let resolvedSocket = socketPath ?? store.socketPath
        let resolvedQueue = queueDir ?? store.inboxDirURL
        guard let payload = try? encodeEvent(event) else { return false }

        if sendOverUnixSocket(payload: payload, socketPath: resolvedSocket) {
            return true
        }
        return enqueue(event, queueDir: resolvedQueue)
    }

    /// Sends raw bytes to a listening POSIX AF_UNIX stream socket.
    public static func sendOverUnixSocket(payload: Data, socketPath: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        // Avoid SIGPIPE terminating the hook CLI if the server closes early.
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard var addr = makeSockAddrUn(path: socketPath) else { return false }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, addrLen)
            }
        }
        guard connected == 0 else { return false }

        return payload.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return false }
            var totalWritten = 0
            while totalWritten < payload.count {
                let n = Darwin.write(fd, base.advanced(by: totalWritten), payload.count - totalWritten)
                if n <= 0 {
                    return false
                }
                totalWritten += n
            }
            return true
        }
    }

    /// Drains all queued `.json` events in sorted filename order and removes processed files.
    public static func drainQueue(dir: URL) -> [HookEvent] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let jsonFiles = entries
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var events: [HookEvent] = []
        for fileURL in jsonFiles {
            if let text = try? String(contentsOf: fileURL, encoding: .utf8),
               let event = try? decodeEvent(text) {
                events.append(event)
            }
            try? fm.removeItem(at: fileURL)
        }
        return events
    }

    private static func makeSockAddrUn(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard utf8.count <= maxLen else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (idx, byte) in utf8.enumerated() {
                buf[idx] = byte
            }
            buf[utf8.count] = 0
        }
        return addr
    }
}
