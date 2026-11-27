import CoreServices
import Foundation

/// Native macOS FSEvents watcher with 300ms trailing debounce.
/// Watches all discovered `.trellis/` directories plus `~/.trellis/channels/`.
public final class FSEventsWatcher: @unchecked Sendable {
    public enum ChangeKind: Sendable {
        case workspace
        case channel
        case both
    }

    private let queue = DispatchQueue(label: "com.superjinge.trellis-hud.fsevents", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let debounceInterval: TimeInterval
    private let onChange: @Sendable (ChangeKind) -> Void

    private var streamRef: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private var pendingDebounce: DispatchWorkItem?
    private var pendingKind: ChangeKind?
    private let channelsRoot: String

    public init(
        debounceInterval: TimeInterval = 0.30,
        channelsRoot: String? = nil,
        onChange: @escaping @Sendable (ChangeKind) -> Void
    ) {
        self.debounceInterval = debounceInterval
        self.channelsRoot = channelsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".trellis/channels").path
        self.onChange = onChange
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    /// Updates the watched directory set. Automatically includes `~/.trellis/channels/` if present.
    public func updatePaths(_ trellisDirs: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            var desired = Set(trellisDirs.filter { FileManager.default.fileExists(atPath: $0) })
            if FileManager.default.fileExists(atPath: self.channelsRoot) {
                desired.insert(self.channelsRoot)
            } else {
                let homeTrellis = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".trellis").path
                if FileManager.default.fileExists(atPath: homeTrellis) {
                    desired.insert(homeTrellis)
                }
            }
            let sorted = desired.sorted()
            guard sorted != self.watchedPaths else { return }
            self.watchedPaths = sorted
            self.restartStreamLocked()
        }
    }

    /// Safe to invoke from any queue, including `deinit` triggered on `self.queue` (prevents `queue.sync` deadlock).
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
        pendingDebounce?.cancel()
        pendingDebounce = nil
        pendingKind = nil
        tearDownStreamLocked()
    }

    private func tearDownStreamLocked() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }

    private func restartStreamLocked() {
        tearDownStreamLocked()
        guard !watchedPaths.isEmpty else { return }

        let pathsToWatch = watchedPaths as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, _, _ in
            guard let clientInfo else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            var paths: [String] = []
            paths.reserveCapacity(numEvents)
            for idx in 0..<numEvents {
                if let ptr = CFArrayGetValueAtIndex(cfArray, idx) {
                    let cfStr = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue()
                    paths.append(cfStr as String)
                }
            }
            watcher.handleRawPaths(paths)
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagIgnoreSelf
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        streamRef = stream
    }

    private func handleRawPaths(_ paths: [String]) {
        var sawChannel = false
        var sawWorkspace = false

        for path in paths {
            if path.hasPrefix(channelsRoot) || path.contains("/.trellis/channels/") {
                if path.hasSuffix(".jsonl") || path.hasSuffix(".json") || path.hasSuffix("/channels") {
                    sawChannel = true
                }
            } else if isRelevantWorkspacePath(path) {
                sawWorkspace = true
            }
        }

        guard sawChannel || sawWorkspace else { return }

        let incoming: ChangeKind = switch (sawWorkspace, sawChannel) {
        case (true, true): .both
        case (true, false): .workspace
        case (false, true): .channel
        case (false, false): .workspace
        }

        switch (pendingKind, incoming) {
        case (nil, _):
            pendingKind = incoming
        case (.both, _), (_, .both):
            pendingKind = .both
        case (.workspace, .channel), (.channel, .workspace):
            pendingKind = .both
        default:
            break
        }

        pendingDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let kind = self.pendingKind else { return }
            self.pendingKind = nil
            self.onChange(kind)
        }
        pendingDebounce = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func isRelevantWorkspacePath(_ path: String) -> Bool {
        if path.contains("/.trellis/tasks/") {
            let file = URL(fileURLWithPath: path).lastPathComponent
            if file == "task.json" || file == "implement.jsonl" || file == "check.jsonl" || file.hasSuffix(".md") {
                return true
            }
        }
        if path.contains("/.trellis/spec/") && path.hasSuffix(".md") {
            return true
        }
        if path.contains("/.trellis/workspace/") && path.hasSuffix(".md") {
            return true
        }
        if path.contains("/.trellis/.runtime/sessions/") && path.hasSuffix(".json") {
            return true
        }
        if path.hasSuffix("/.trellis/.current-task") || path.hasSuffix("/.trellis/config.yaml") {
            return true
        }
        return false
    }
}
