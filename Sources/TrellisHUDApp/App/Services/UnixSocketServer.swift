import Darwin
import Foundation
import TrellisCore

/// POSIX `AF_UNIX` stream socket server + inbox fallback queue poller.
/// Wire-compatible with `trellis-card`'s `/tmp/trellis-card-<fnv1a>.sock` newline-JSON protocol.
public final class HUDUnixSocketServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.superjinge.trellis-hud.ipc", qos: .userInitiated)
    private let socketPaths: [String]
    private let inboxDirs: [URL]
    private let onEvents: @Sendable ([HookEvent]) -> Void

    private var serverSockets: [Int32] = []
    private var acceptSources: [DispatchSourceRead] = []
    private var inboxTimer: DispatchSourceTimer?
    private let decoder = JSONDecoder()

    public init(
        socketPaths: [String]? = nil,
        inboxDirs: [URL]? = nil,
        onEvents: @escaping @Sendable ([HookEvent]) -> Void
    ) {
        self.socketPaths = socketPaths ?? Self.defaultSocketPaths()
        self.inboxDirs = inboxDirs ?? Self.defaultInboxDirs()
        self.onEvents = onEvents
    }

    deinit {
        stop()
    }

    /// Computes both the macOS `Application Support/trellis-card` hash (used by Rust `dirs::config_dir()`)
    /// and the `~/.config/trellis-card` hash so existing `trellis-card` hooks AND new Swift hooks deliver seamlessly.
    public static func defaultSocketPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupportDir = home
            .appendingPathComponent("Library/Application Support/trellis-card").path
        let dotConfigDir = home
            .appendingPathComponent(".config/trellis-card").path
        var result: [String] = []
        for dir in [appSupportDir, dotConfigDir] {
            let sock = "/tmp/trellis-card-\(fnv1aHex(dir)).sock"
            if !result.contains(sock) {
                result.append(sock)
            }
        }
        return result
    }

    public static func defaultInboxDirs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/trellis-card/inbox", isDirectory: true),
            home.appendingPathComponent(".config/trellis-card/inbox", isDirectory: true),
        ]
    }

    public static func fnv1aHex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            for path in self.socketPaths {
                self.bindSocketLocked(at: path)
            }
            self.startInboxPollerLocked()
        }
    }

    public func stop() {
        queue.sync {
            stopLocked()
        }
    }

    private func stopLocked() {
        inboxTimer?.cancel()
        inboxTimer = nil

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

        // Set non-blocking for DispatchSourceRead
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
            readClientPayload(fd: clientFD)
        }
    }

    private func readClientPayload(fd: Int32) {
        defer { Darwin.close(fd) }
        // Make sure client read has a short timeout so a misbehaving client never stalls the server
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                if data.count > 262_144 { break } // 256 KB safety cap
            } else {
                break
            }
        }

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        let events = decodeLines(text)
        if !events.isEmpty {
            onEvents(events)
        }
    }

    private func startInboxPollerLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.drainInboxesLocked()
        }
        timer.resume()
        inboxTimer = timer
    }

    private func drainInboxesLocked() {
        var collected: [HookEvent] = []
        let fm = FileManager.default

        for dir in inboxDirs {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            let jsonFiles = items
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for fileURL in jsonFiles {
                if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                    collected.append(contentsOf: decodeLines(text))
                }
                try? fm.removeItem(at: fileURL)
            }
        }

        if !collected.isEmpty {
            onEvents(collected)
        }
    }

    private func decodeLines(_ text: String) -> [HookEvent] {
        var results: [HookEvent] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            if let event = try? decoder.decode(HookEvent.self, from: lineData) {
                results.append(event)
            }
        }
        return results
    }
}
