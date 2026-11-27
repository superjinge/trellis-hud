import Darwin
import Foundation
import TrellisCore

/// POSIX `AF_UNIX` stream socket server + event-driven inbox fallback watcher.
/// Delegates FNV-1a socket hashing, `0600` owner-only permissions, NDJSON decoding, and inbox draining
/// directly to `TrellisCore.ConfigStore` & `TrellisCore.UnixSocketProtocol`.
public final class HUDUnixSocketServer: @unchecked Sendable {
    private static let maxClientPayloadBytes = 2 * 1024 * 1024 // 2 MiB safety cap

    private let queue = DispatchQueue(label: "com.superjinge.trellis-hud.ipc.accept", qos: .userInitiated)
    private let clientReadQueue = DispatchQueue(
        label: "com.superjinge.trellis-hud.ipc.client-read",
        qos: .utility,
        attributes: .concurrent
    )
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let socketPaths: [String]
    private let inboxDirs: [URL]
    private let onEvents: @Sendable ([HookEvent]) -> Void

    private var serverSockets: [Int32] = []
    private var acceptSources: [DispatchSourceRead] = []
    private var inboxWatchSources: [DispatchSourceFileSystemObject] = []
    private var inboxWatchFDs: [Int32] = []
    private var fallbackTimer: DispatchSourceTimer?

    public init(
        socketPaths: [String]? = nil,
        inboxDirs: [URL]? = nil,
        onEvents: @escaping @Sendable ([HookEvent]) -> Void
    ) {
        self.socketPaths = socketPaths ?? Self.defaultSocketPaths()
        self.inboxDirs = inboxDirs ?? Self.defaultInboxDirs()
        self.onEvents = onEvents
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    /// Computes both `Application Support/trellis-card` (canonical macOS `ConfigStore`) and `~/.config/trellis-card`
    /// socket paths via `TrellisCore.ConfigStore.socketPath(for:)` so legacy & new hooks both deliver cleanly.
    public static func defaultSocketPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            ConfigStore.defaultConfigDir().path,
            home.appendingPathComponent("Library/Application Support/trellis-card").path,
            home.appendingPathComponent(".config/trellis-card").path,
        ]
        var result: [String] = []
        for dir in candidates {
            let sock = ConfigStore.socketPath(for: dir)
            if !result.contains(sock) {
                result.append(sock)
            }
        }
        return result
    }

    public static func defaultInboxDirs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let urls = [
            ConfigStore.defaultConfigDir().appendingPathComponent("inbox", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/trellis-card/inbox", isDirectory: true),
            home.appendingPathComponent(".config/trellis-card/inbox", isDirectory: true),
        ]
        var unique: [URL] = []
        for u in urls where !unique.contains(where: { $0.path == u.path }) {
            unique.append(u)
        }
        return unique
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            for path in self.socketPaths {
                self.bindSocketLocked(at: path)
            }
            self.drainInboxesLocked()
            self.startInboxWatchersLocked()
        }
    }

    /// Safe to invoke from any queue, including `deinit` running on `self.queue` (avoids `queue.sync` deadlock).
    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopLocked()
        } else {
            queue.sync {
                stopLocked()
            }
        }
    }

    private func stopLocked() {
        fallbackTimer?.cancel()
        fallbackTimer = nil

        for source in inboxWatchSources {
            source.cancel()
        }
        inboxWatchSources.removeAll()
        for fd in inboxWatchFDs {
            Darwin.close(fd)
        }
        inboxWatchFDs.removeAll()

        for source in acceptSources {
            source.cancel()
        }
        acceptSources.removeAll()

        for fd in serverSockets {
            Darwin.close(fd)
        }
        serverSockets.removeAll()

        for path in socketPaths {
            unlink(path)
        }
    }

    private func bindSocketLocked(at path: String) {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            Darwin.close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                for i in 0..<pathBytes.count {
                    dst[i] = pathBytes[i]
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 32) == 0 else {
            Darwin.close(fd)
            return
        }

        // Restrict socket permissions strictly to the current user (0600)
        UnixSocketProtocol.setOwnerOnlyPermissions(socketPath: path)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnectionsLocked(serverFD: fd)
        }
        source.resume()

        serverSockets.append(fd)
        acceptSources.append(source)
    }

    private func acceptPendingConnectionsLocked(serverFD: Int32) {
        while true {
            var clientAddr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(serverFD, sockPtr, &len)
                }
            }
            if clientFD < 0 {
                break
            }
            let deliver = onEvents
            clientReadQueue.async {
                Self.readClientPayload(fd: clientFD, onEvents: deliver)
            }
        }
    }

    private static func readClientPayload(
        fd: Int32,
        onEvents: @escaping @Sendable ([HookEvent]) -> Void
    ) {
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                let remaining = maxClientPayloadBytes - data.count
                if remaining <= 0 { break }
                data.append(contentsOf: buffer[0..<min(count, remaining)])
                if data.count >= maxClientPayloadBytes { break }
            } else {
                break
            }
        }

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        var events: [HookEvent] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let event = try? UnixSocketProtocol.decodeEvent(trimmed) {
                events.append(event)
            }
        }
        if !events.isEmpty {
            onEvents(events)
        }
    }

    private func startInboxWatchersLocked() {
        for dir in inboxDirs {
            attachVnodeWatcherLocked(for: dir)
        }
        // Low-power 3-second fallback handles inboxes created after startup (replaces 250ms busy polling).
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(3), repeating: .seconds(3), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.drainInboxesLocked()
            if self.inboxWatchSources.count < self.inboxDirs.count {
                self.reattachMissingVnodeWatchersLocked()
            }
        }
        timer.resume()
        fallbackTimer = timer
    }

    private func attachVnodeWatcherLocked(for dir: URL) {
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.drainInboxesLocked()
        }
        source.resume()
        inboxWatchFDs.append(fd)
        inboxWatchSources.append(source)
    }

    private func reattachMissingVnodeWatchersLocked() {
        let existingCount = inboxWatchSources.count
        guard existingCount < inboxDirs.count else { return }
        for source in inboxWatchSources { source.cancel() }
        inboxWatchSources.removeAll()
        for fd in inboxWatchFDs { Darwin.close(fd) }
        inboxWatchFDs.removeAll()
        for dir in inboxDirs {
            attachVnodeWatcherLocked(for: dir)
        }
    }

    private func drainInboxesLocked() {
        var collected: [HookEvent] = []
        for dir in inboxDirs {
            let events = UnixSocketProtocol.drainQueue(dir: dir)
            if !events.isEmpty {
                collected.append(contentsOf: events)
            }
        }
        if !collected.isEmpty {
            onEvents(collected)
        }
    }
}
