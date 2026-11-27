import Darwin
import Foundation

/// Wire-compatible NDJSON Unix domain socket + atomic inbox queue fallback.
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
        let tempURL = targetURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            try fm.moveItem(at: tempURL, to: targetURL)
            return true
        } catch {
            try? fm.removeItem(at: tempURL)
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

    fileprivate static func makeSockAddrUn(path: String) -> sockaddr_un? {
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

/// POSIX AF_UNIX stream socket listener for receiving real-time `HookEvent` lines.
public final class UnixSocketServer: @unchecked Sendable {
    public let socketPath: String
    private let queue = DispatchQueue(label: "com.superjinge.trellis-hud.unix-socket-server", qos: .userInitiated)
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var isRunning = false

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    public func start(onEvent: @escaping @Sendable (HookEvent) -> Void) throws {
        lock.lock()
        if isRunning {
            lock.unlock()
            return
        }

        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        Darwin.unlink(socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lock.unlock()
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard var addr = UnixSocketProtocol.makeSockAddrUn(path: socketPath) else {
            Darwin.close(fd)
            lock.unlock()
            throw POSIXError(.ENAMETOOLONG)
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            lock.unlock()
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EADDRINUSE)
        }

        guard Darwin.listen(fd, 64) == 0 else {
            let err = errno
            Darwin.close(fd)
            Darwin.unlink(socketPath)
            lock.unlock()
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }

        self.listenFD = fd
        self.isRunning = true
        lock.unlock()

        queue.async { [weak self] in
            self?.acceptLoop(fd: fd, onEvent: onEvent)
        }
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        isRunning = false
        lock.unlock()

        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        Darwin.unlink(socketPath)
    }

    private func acceptLoop(fd: Int32, onEvent: @escaping @Sendable (HookEvent) -> Void) {
        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD < 0 {
                lock.lock()
                let running = isRunning
                lock.unlock()
                if !running || errno == EBADF || errno == EINVAL {
                    break
                }
                continue
            }
            handleClient(clientFD: clientFD, onEvent: onEvent)
            Darwin.close(clientFD)
        }
    }

    private func handleClient(clientFD: Int32, onEvent: @Sendable (HookEvent) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(clientFD, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }
        guard let text = String(data: buffer, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            if let event = try? UnixSocketProtocol.decodeEvent(String(line)) {
                onEvent(event)
            }
        }
    }
}
