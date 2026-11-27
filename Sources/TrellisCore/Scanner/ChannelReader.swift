import Foundation

/// Reads and reduces Trellis multi-agent channel event logs (`~/.trellis/channels/<project>/<channel>/events.jsonl`)
/// into `ChannelInfo`, `ChannelWorkerState`, `ChannelThread`, and `ChannelMessage`.
///
/// Mirrors the exact reduction semantics of `Trellis/packages/core/src/channel/internal/store/`.
public enum ChannelReader: Sendable {
    public static let globalProjectKey = "_global"

    /// Resolves the root directory for Trellis channel stores (`$TRELLIS_CHANNEL_ROOT` or `~/.trellis/channels`).
    public static func defaultChannelRoot(homeDirectory: String? = nil) -> String {
        if let env = ProcessInfo.processInfo.environment["TRELLIS_CHANNEL_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        let home = homeDirectory ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".trellis/channels")
    }

    /// Derives the Trellis channel project bucket key from an absolute project path.
    /// Mirrors `Trellis/packages/core/src/channel/internal/store/paths.ts::projectKey`.
    public static func projectKey(for projectPath: String) -> String {
        let abs = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath).standardizedFileURL.path
        var out = ""
        out.reserveCapacity(abs.count)
        for ch in abs {
            if ch == "/" || ch == "\\" || ch == "_" {
                out.append("-")
            } else if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "-") {
                out.append(ch)
            } else {
                out.append("-")
            }
        }
        return out
    }

    /// Scans Trellis channels for a specific project (plus `_global`), or across all project buckets when `projectPath == nil`.
    /// Gracefully returns `[]` if the directory does not exist or contains malformed lines.
    public static func scanChannels(
        projectPath: String? = nil,
        channelRoot: String? = nil,
        includeEphemeral: Bool = false,
        maxRecentMessages: Int = 50
    ) -> [ChannelInfo] {
        let root = channelRoot ?? defaultChannelRoot()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let bucketNames: [String]
        if let projectPath {
            let key = projectKey(for: projectPath)
            bucketNames = Array(Set([key, globalProjectKey]))
        } else {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
            bucketNames = entries.filter { !$0.hasPrefix(".") && $0 != "_legacy" }
        }

        var channels: [ChannelInfo] = []
        for bucket in bucketNames {
            let bucketDir = (root as NSString).appendingPathComponent(bucket)
            var bIsDir: ObjCBool = false
            guard fm.fileExists(atPath: bucketDir, isDirectory: &bIsDir), bIsDir.boolValue else {
                continue
            }
            guard let channelDirs = try? fm.contentsOfDirectory(atPath: bucketDir) else { continue }
            let scope: ChannelScope = bucket == globalProjectKey ? .global : .project

            for channelName in channelDirs where !channelName.hasPrefix(".") {
                let dirPath = (bucketDir as NSString).appendingPathComponent(channelName)
                let eventsFile = (dirPath as NSString).appendingPathComponent("events.jsonl")
                guard fm.fileExists(atPath: eventsFile),
                      let content = try? String(contentsOfFile: eventsFile, encoding: .utf8)
                else { continue }

                let (info, isEphemeral) = parseChannelEventsWithEphemeralFlag(
                    jsonlContent: content,
                    name: channelName,
                    scope: scope,
                    projectKey: bucket,
                    dirPath: dirPath,
                    maxRecentMessages: maxRecentMessages
                )
                if isEphemeral && !includeEphemeral && info.activeWorkers.isEmpty {
                    continue
                }
                channels.append(info)
            }
        }

        return channels.sorted { lhs, rhs in
            let lDate = lhs.updatedAt ?? .distantPast
            let rDate = rhs.updatedAt ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.name < rhs.name
        }
    }

    /// Reduces raw `events.jsonl` content into a `ChannelInfo` snapshot.
    /// Malformed JSONL lines are skipped safely without throwing.
    public static func parseChannelEvents(
        jsonlContent: String,
        name: String,
        scope: ChannelScope = .project,
        projectKey: String,
        dirPath: String,
        maxRecentMessages: Int = 50
    ) -> ChannelInfo {
        parseChannelEventsWithEphemeralFlag(
            jsonlContent: jsonlContent,
            name: name,
            scope: scope,
            projectKey: projectKey,
            dirPath: dirPath,
            maxRecentMessages: maxRecentMessages
        ).info
    }

    // MARK: - Event Reduction

    private struct RawEvent {
        let seq: Int
        let tsString: String?
        let tsDate: Date?
        let kind: String
        let by: String
        let to: [String]
        let origin: String?
        let dict: [String: Any]
    }

    private struct WorkerAccumulator {
        var state: ChannelWorkerState
        var consumedInputSeq: Int
    }

    private struct ThreadAccumulator {
        var thread: String
        var title: String?
        var status: String = "open"
        var labels: [String] = []
        var assignees: [String] = []
        var description: String?
        var summary: String?
        var contextMap: [String: ChannelContextEntry] = [:]
        var openedAt: Date?
        var updatedAt: Date?
        var lastSeq: Int = 0
        var comments: Int = 0
    }

    private static func parseChannelEventsWithEphemeralFlag(
        jsonlContent: String,
        name: String,
        scope: ChannelScope,
        projectKey: String,
        dirPath: String,
        maxRecentMessages: Int
    ) -> (info: ChannelInfo, isEphemeral: Bool) {
        var events: [RawEvent] = []
        for rawLine in jsonlContent.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = obj["kind"] as? String
            else { continue }

            let seq = intValue(obj["seq"]) ?? (events.count + 1)
            let tsString = obj["ts"] as? String
            let tsDate = tsString.flatMap(parseISO8601Date)
            let by = (obj["by"] as? String) ?? "unknown"
            let to = parseToTargets(obj["to"])
            let origin = obj["origin"] as? String

            events.append(
                RawEvent(
                    seq: seq,
                    tsString: tsString,
                    tsDate: tsDate,
                    kind: kind,
                    by: by,
                    to: to,
                    origin: origin,
                    dict: obj
                )
            )
        }

        // 1. Reduce channel metadata
        var channelType: ChannelType = .chat
        var title: String?
        var description: String?
        var taskRef: String?
        var cwd: String?
        var labels: [String] = []
        var contextMap: [String: ChannelContextEntry] = [:]
        var isEphemeral = false
        var lastSeq = 0
        var updatedAt: Date?

        for ev in events {
            if ev.seq > lastSeq { lastSeq = ev.seq }
            if let d = ev.tsDate, updatedAt == nil || d > updatedAt! {
                updatedAt = d
            }

            switch ev.kind {
            case "create":
                if let rawType = ev.dict["type"] as? String, rawType == "forum" {
                    channelType = .forum
                } else {
                    channelType = .chat
                }
                if let desc = ev.dict["description"] as? String { description = desc }
                if let task = ev.dict["task"] as? String { taskRef = task }
                if let dir = ev.dict["cwd"] as? String { cwd = dir }
                if let lbls = ev.dict["labels"] as? [String] { labels = lbls }
                if let eph = ev.dict["ephemeral"] as? Bool { isEphemeral = eph }
                let initial = parseContextEntries(ev.dict["context"]) ?? parseContextEntries(ev.dict["linkedContext"])
                contextMap.removeAll()
                for entry in initial ?? [] {
                    contextMap[contextKey(entry)] = entry
                }
            case "context":
                if (ev.dict["target"] as? String) == "channel",
                   let entries = parseContextEntries(ev.dict["context"])
                {
                    let action = ev.dict["action"] as? String
                    if action == "add" {
                        for entry in entries { contextMap[contextKey(entry)] = entry }
                    } else if action == "delete" {
                        for entry in entries { contextMap.removeValue(forKey: contextKey(entry)) }
                    }
                }
            case "channel":
                if (ev.dict["action"] as? String) == "title" {
                    if let next = ev.dict["title"] as? String, !next.isEmpty {
                        title = next
                    } else {
                        title = nil
                    }
                }
            default:
                break
            }
        }

        // 2. Reduce threads (with rename alias flattening)
        let threads = reduceThreads(events: events)

        // 3. Reduce workers + pending inbox counts
        let workers = reduceWorkers(events: events, channelName: name)

        // 4. Collect recent human-visible messages
        var messages: [ChannelMessage] = []
        for ev in events {
            if let msg = toChannelMessage(ev, channelName: name) {
                messages.append(msg)
            }
        }
        if maxRecentMessages > 0 && messages.count > maxRecentMessages {
            messages = Array(messages.suffix(maxRecentMessages))
        }

        let info = ChannelInfo(
            name: name,
            scope: scope,
            projectKey: projectKey,
            dirPath: dirPath,
            type: channelType,
            title: title,
            description: description,
            taskRef: taskRef,
            cwd: cwd,
            labels: labels,
            context: Array(contextMap.values),
            workers: workers,
            threads: threads,
            recentMessages: messages,
            lastSeq: lastSeq,
            updatedAt: updatedAt
        )
        return (info, isEphemeral)
    }

    private static func reduceThreads(events: [RawEvent]) -> [ChannelThread] {
        var aliasToCurrent: [String: String] = [:]
        var aliasesByCurrent: [String: Set<String>] = [:]

        func resolve(_ key: String) -> String {
            var cur = aliasToCurrent[key] ?? key
            var seen = Set<String>()
            while let next = aliasToCurrent[cur], seen.insert(cur).inserted {
                cur = next
            }
            return cur
        }

        for ev in events where ev.kind == "thread" && (ev.dict["action"] as? String) == "rename" {
            guard let oldKey = ev.dict["thread"] as? String,
                  let newKey = (ev.dict["newThread"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !oldKey.isEmpty, !newKey.isEmpty, oldKey != newKey
            else { continue }

            let oldCurrent = resolve(oldKey)
            let targetCurrent = resolve(newKey)
            if oldCurrent == targetCurrent { continue }

            var moving = aliasesByCurrent.removeValue(forKey: oldCurrent) ?? []
            moving.insert(oldCurrent)

            var targetSet = aliasesByCurrent[targetCurrent] ?? []
            for alias in moving {
                if alias != targetCurrent { targetSet.insert(alias) }
                aliasToCurrent[alias] = targetCurrent
            }
            aliasesByCurrent[targetCurrent] = targetSet
        }

        var states: [String: ThreadAccumulator] = [:]
        for ev in events {
            if ev.kind == "thread", let rawThread = ev.dict["thread"] as? String, !rawThread.isEmpty {
                let canonical = resolve(rawThread)
                var acc = states[canonical] ?? ThreadAccumulator(thread: canonical, lastSeq: ev.seq)
                if let d = ev.tsDate {
                    acc.updatedAt = d
                    if acc.openedAt == nil { acc.openedAt = d }
                }
                acc.lastSeq = ev.seq

                switch ev.dict["action"] as? String {
                case "opened":
                    acc.status = (ev.dict["status"] as? String) ?? "open"
                    if let t = ev.dict["title"] as? String { acc.title = t }
                    if let d = ev.dict["description"] as? String { acc.description = d }
                    if let lbls = ev.dict["labels"] as? [String] { acc.labels = lbls }
                    if let ass = ev.dict["assignees"] as? [String] { acc.assignees = ass }
                    if let entries = parseContextEntries(ev.dict["context"]) ?? parseContextEntries(ev.dict["linkedContext"]) {
                        acc.contextMap.removeAll()
                        for entry in entries { acc.contextMap[contextKey(entry)] = entry }
                    }
                case "comment":
                    acc.comments += 1
                case "status":
                    if let st = ev.dict["status"] as? String { acc.status = st }
                case "labels":
                    if let lbls = ev.dict["labels"] as? [String] { acc.labels = lbls }
                case "assignees":
                    if let ass = ev.dict["assignees"] as? [String] { acc.assignees = ass }
                case "summary":
                    if let sum = ev.dict["summary"] as? String { acc.summary = sum }
                case "processed":
                    acc.status = (ev.dict["status"] as? String) ?? "processed"
                default:
                    break
                }
                states[canonical] = acc
            } else if ev.kind == "context",
                      (ev.dict["target"] as? String) == "thread",
                      let rawThread = ev.dict["thread"] as? String,
                      let entries = parseContextEntries(ev.dict["context"])
            {
                let canonical = resolve(rawThread)
                guard var acc = states[canonical] else { continue }
                let action = ev.dict["action"] as? String
                if action == "add" {
                    for entry in entries { acc.contextMap[contextKey(entry)] = entry }
                } else if action == "delete" {
                    for entry in entries { acc.contextMap.removeValue(forKey: contextKey(entry)) }
                }
                if let d = ev.tsDate { acc.updatedAt = d }
                acc.lastSeq = ev.seq
                states[canonical] = acc
            }
        }

        return states.values.map { acc in
            ChannelThread(
                thread: acc.thread,
                title: acc.title,
                status: acc.status,
                labels: acc.labels,
                assignees: acc.assignees,
                description: acc.description,
                summary: acc.summary,
                context: Array(acc.contextMap.values),
                openedAt: acc.openedAt,
                updatedAt: acc.updatedAt,
                lastSeq: acc.lastSeq,
                comments: acc.comments,
                aliases: Array(aliasesByCurrent[acc.thread] ?? []).sorted()
            )
        }.sorted { lhs, rhs in
            (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
    }

    private static func reduceWorkers(events: [RawEvent], channelName: String) -> [ChannelWorkerState] {
        var accMap: [String: WorkerAccumulator] = [:]

        for ev in events {
            guard let ident = identifyWorker(ev) else { continue }
            var acc: WorkerAccumulator
            if let existing = accMap[ident.id] {
                acc = existing
            } else {
                guard ident.canCreate else { continue }
                acc = WorkerAccumulator(
                    state: ChannelWorkerState(
                        workerId: ident.id,
                        channelName: channelName,
                        lifecycle: .running,
                        activity: .idle,
                        pendingMessageCount: 0,
                        inboxPolicy: .explicitOnly,
                        updatedAt: ev.tsDate ?? Date(),
                        lastSeq: ev.seq
                    ),
                    consumedInputSeq: 0
                )
            }

            if let d = ev.tsDate { acc.state.updatedAt = d }
            acc.state.lastSeq = ev.seq

            switch ev.kind {
            case "spawned":
                acc.state.lifecycle = .running
                acc.state.activity = .idle
                acc.state.activeTurnId = nil
                acc.state.activeTurnStartedAt = nil
                acc.state.exitCode = nil
                acc.state.signal = nil
                acc.state.reason = nil
                acc.state.lastError = nil
                acc.state.spawnedAt = ev.tsDate
                acc.state.idleSince = ev.tsDate
                acc.state.startedBy = ev.by
                if let provider = ev.dict["provider"] as? String { acc.state.provider = provider }
                if let agent = ev.dict["agent"] as? String { acc.state.agent = agent }
                if let rawPolicy = ev.dict["inboxPolicy"] as? String,
                   let policy = ChannelInboxPolicy(rawValue: rawPolicy)
                {
                    acc.state.inboxPolicy = policy
                }
            case "turn_started":
                acc.state.activity = .midTurn
                acc.state.activeTurnId = ev.dict["turnId"] as? String
                acc.state.activeTurnStartedAt = ev.tsDate
                acc.state.idleSince = nil
                if let inputSeq = intValue(ev.dict["inputSeq"]), inputSeq > acc.consumedInputSeq {
                    acc.consumedInputSeq = inputSeq
                }
            case "turn_finished", "interrupted":
                acc.state.activity = .idle
                acc.state.activeTurnId = nil
                acc.state.activeTurnStartedAt = nil
                acc.state.idleSince = ev.tsDate
            case "done":
                acc.state.activity = .idle
                acc.state.activeTurnId = nil
                acc.state.activeTurnStartedAt = nil
                if (ev.dict["synthesized"] as? Bool) == true {
                    acc.state.lifecycle = .done
                    acc.state.exitCode = intValue(ev.dict["exit_code"]) ?? acc.state.exitCode
                    acc.state.idleSince = nil
                } else {
                    acc.state.idleSince = ev.tsDate
                }
            case "error":
                acc.state.activity = .idle
                acc.state.activeTurnId = nil
                acc.state.activeTurnStartedAt = nil
                if let msg = ev.dict["message"] as? String { acc.state.lastError = msg }
                if (ev.dict["synthesized"] as? Bool) == true || ev.by.hasPrefix("supervisor:") {
                    acc.state.lifecycle = .error
                    acc.state.exitCode = intValue(ev.dict["exit_code"]) ?? acc.state.exitCode
                    acc.state.signal = (ev.dict["exit_signal"] as? String) ?? acc.state.signal
                    acc.state.idleSince = nil
                } else {
                    acc.state.idleSince = ev.tsDate
                }
            case "killed":
                let reason = ev.dict["reason"] as? String
                acc.state.lifecycle = reason == "crash" ? .crashed : .killed
                acc.state.activity = .idle
                acc.state.activeTurnId = nil
                acc.state.activeTurnStartedAt = nil
                acc.state.idleSince = nil
                acc.state.reason = reason ?? acc.state.reason
                acc.state.signal = (ev.dict["signal"] as? String) ?? acc.state.signal
            default:
                break
            }

            accMap[ident.id] = acc
        }

        // Second pass: durable pending message count matching inboxPolicy.
        var workers: [ChannelWorkerState] = []
        for (_, var acc) in accMap {
            if acc.state.isTerminal {
                acc.state.pendingMessageCount = 0
            } else {
                var pending = 0
                for ev in events where ev.seq > acc.consumedInputSeq {
                    if matchesInboxPolicy(ev: ev, workerId: acc.state.workerId, policy: acc.state.inboxPolicy) {
                        pending += 1
                    }
                }
                acc.state.pendingMessageCount = pending
            }
            workers.append(acc.state)
        }

        return workers.sorted { $0.workerId < $1.workerId }
    }

    private static func identifyWorker(_ ev: RawEvent) -> (id: String, canCreate: Bool)? {
        switch ev.kind {
        case "spawned":
            guard let id = ev.dict["as"] as? String, !id.isEmpty else { return nil }
            return (id, true)
        case "turn_started", "turn_finished", "interrupt_requested", "interrupted":
            guard let id = ev.dict["worker"] as? String, !id.isEmpty else { return nil }
            return (id, false)
        case "killed":
            if let explicit = (ev.dict["worker"] as? String) ?? (ev.dict["as"] as? String), !explicit.isEmpty {
                return (explicit, true)
            }
            if ev.by.hasPrefix("supervisor:") {
                return (String(ev.by.dropFirst("supervisor:".count)), true)
            }
            return (ev.by, false)
        case "done", "error":
            if let explicit = (ev.dict["worker"] as? String) ?? (ev.dict["as"] as? String), !explicit.isEmpty {
                return (explicit, true)
            }
            if ev.by.hasPrefix("supervisor:") {
                return (String(ev.by.dropFirst("supervisor:".count)), true)
            }
            return (ev.by, false)
        default:
            return nil
        }
    }

    private static func matchesInboxPolicy(
        ev: RawEvent,
        workerId: String,
        policy: ChannelInboxPolicy
    ) -> Bool {
        guard ev.kind == "message", ev.by != workerId else { return false }
        if !ev.to.isEmpty {
            return ev.to.contains(workerId)
        }
        return policy == .broadcastAndExplicit
    }

    private static func toChannelMessage(_ ev: RawEvent, channelName: String) -> ChannelMessage? {
        let ts = ev.tsDate ?? Date()
        switch ev.kind {
        case "message":
            let text = (ev.dict["text"] as? String) ?? ""
            return ChannelMessage(
                channelName: channelName,
                seq: ev.seq,
                timestamp: ts,
                kind: ev.kind,
                by: ev.by,
                to: ev.to,
                text: text,
                thread: ev.dict["thread"] as? String,
                origin: ev.origin
            )
        case "thread":
            let text = (ev.dict["text"] as? String)
                ?? (ev.dict["summary"] as? String)
                ?? (ev.dict["title"] as? String)
                ?? ""
            guard !text.isEmpty else { return nil }
            return ChannelMessage(
                channelName: channelName,
                seq: ev.seq,
                timestamp: ts,
                kind: ev.kind,
                by: ev.by,
                to: ev.to,
                text: text,
                thread: ev.dict["thread"] as? String,
                origin: ev.origin
            )
        case "error", "supervisor_warning":
            let text = (ev.dict["message"] as? String) ?? (ev.dict["reason"] as? String) ?? ev.kind
            return ChannelMessage(
                channelName: channelName,
                seq: ev.seq,
                timestamp: ts,
                kind: ev.kind,
                by: ev.by,
                to: ev.to,
                text: text,
                thread: nil,
                origin: ev.origin
            )
        default:
            return nil
        }
    }

    private static func parseToTargets(_ raw: Any?) -> [String] {
        if let single = raw as? String, !single.isEmpty { return [single] }
        if let arr = raw as? [String] { return arr.filter { !$0.isEmpty } }
        return []
    }

    private static func parseContextEntries(_ raw: Any?) -> [ChannelContextEntry]? {
        guard let arr = raw as? [[String: Any]] else { return nil }
        var out: [ChannelContextEntry] = []
        for item in arr {
            guard let type = item["type"] as? String else { continue }
            if type == "file", let p = item["path"] as? String, !p.isEmpty {
                out.append(.file(path: p))
            } else if type == "raw", let t = item["text"] as? String, !t.isEmpty {
                out.append(.raw(text: t))
            }
        }
        return out
    }

    private static func contextKey(_ entry: ChannelContextEntry) -> String {
        switch entry {
        case .file(let path): return "file:\(path)"
        case .raw(let text): return "raw:\(text)"
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        return nil
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: value) { return d }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}
