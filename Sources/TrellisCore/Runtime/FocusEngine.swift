import Foundation

/// Computes HUD focus selection with attention prioritization and anti-thrash hysteresis.
/// Ported and refined from `trellis-card/src-tauri/src/focus.rs`.
public enum FocusEngine {
    public struct TaskCandidate: Sendable, Equatable {
        public var task: TaskSnapshot
        public var session: AgentSessionState?
        public var status: RuntimeStatus
        public var score: Int
        public var lastChangedAt: Date

        public init(
            task: TaskSnapshot,
            session: AgentSessionState?,
            status: RuntimeStatus,
            score: Int,
            lastChangedAt: Date
        ) {
            self.task = task
            self.session = session
            self.status = status
            self.score = score
            self.lastChangedAt = lastChangedAt
        }
    }

    public static func deriveTaskStatus(task: TaskSnapshot, session: AgentSessionState?) -> RuntimeStatus {
        if task.isDone {
            return .done
        }
        if let session {
            if session.status == .waitingPermission || session.status == .waitingQuestion {
                return session.status
            }
            if task.record.status == "failed" || session.status == .failed {
                return .failed
            }
            if session.status == .working {
                return .working
            }
            if session.status == .done || session.status == .stale {
                return session.status
            }
        }
        if task.record.status == "failed" {
            return .failed
        }
        return .idle
    }

    public static func score(task: TaskSnapshot, session: AgentSessionState?, status: RuntimeStatus) -> Int {
        let base: Int
        switch status {
        case .waitingPermission, .waitingQuestion: base = 1_000
        case .failed: base = 850
        case .working: base = 500
        case .done: base = 300
        case .stale: base = 100
        case .idle: base = task.record.status == "in_progress" ? 120 : 40
        }
        let actionBonus = (session?.lastAction != nil) ? 150 : 0
        let warningBonus = (task.phaseWarning != nil) ? 50 : 0
        let activeBonus = task.archived ? -400 : 0
        return base + actionBonus + warningBonus + activeBonus
    }

    public static func shouldHoldFocus(
        current: TaskCandidate,
        candidate: TaskCandidate,
        now: Date
    ) -> Bool {
        if current.task.id == candidate.task.id {
            return true
        }
        // Attention-requiring candidates always break through ordinary hold timers unless current is also waiting.
        if candidate.status.isAttentionRequired && !current.status.isAttentionRequired {
            return false
        }
        let age = max(0, now.timeIntervalSince(current.lastChangedAt))
        switch current.status {
        case .waitingPermission, .waitingQuestion:
            return age <= 300
        case .done:
            return age <= 3
        default:
            return age < 8
        }
    }

    public static func buildFocusSnapshot(
        tasks: [TaskSnapshot],
        registry: SessionRegistry,
        previousFocusKey: String? = nil,
        now: Date = Date()
    ) -> FocusSnapshot {
        let activeTasks = tasks.filter { !$0.archived }
        let candidates: [TaskCandidate] = activeTasks.map { task in
            let session = registry.latestSession(
                forProject: task.projectPath,
                taskId: task.record.id,
                dir: task.dir
            )
            let status = deriveTaskStatus(task: task, session: session)
            let scoreValue = score(task: task, session: session, status: status)
            let lastChanged = max(task.mtime, session?.updatedAt ?? .distantPast)
            return TaskCandidate(
                task: task,
                session: session,
                status: status,
                score: scoreValue,
                lastChangedAt: lastChanged
            )
        }

        let selected: TaskCandidate? = chooseCandidate(
            candidates: candidates,
            previousFocusKey: previousFocusKey,
            now: now
        )

        let sortedSessions = registry.allSessionsSorted()
        let globalStatus: RuntimeStatus
        if let topSession = sortedSessions.first, topSession.status.isAttentionRequired {
            globalStatus = topSession.status
        } else if let selected {
            globalStatus = selected.status
        } else if let topSession = sortedSessions.first {
            globalStatus = topSession.status
        } else {
            globalStatus = .idle
        }

        return FocusSnapshot(
            focusedTaskKey: selected?.task.id,
            focusedProjectPath: selected?.task.projectPath ?? sortedSessions.first?.projectPath,
            focusedSessionId: selected?.session?.sessionId ?? sortedSessions.first?.sessionId,
            status: globalStatus,
            attentionCount: registry.attentionCount,
            activeSessions: sortedSessions,
            recentActivities: registry.activities(limit: 50),
            updatedAt: now
        )
    }

    private static func chooseCandidate(
        candidates: [TaskCandidate],
        previousFocusKey: String?,
        now: Date
    ) -> TaskCandidate? {
        guard !candidates.isEmpty else { return nil }

        if let previousFocusKey,
           let current = candidates.first(where: { $0.task.id == previousFocusKey }) {
            let challengers = candidates.filter { $0.task.id != previousFocusKey }
            guard let bestChallenger = challengers.max(by: { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.lastChangedAt < rhs.lastChangedAt
            }) else {
                return current
            }
            if shouldHoldFocus(current: current, candidate: bestChallenger, now: now) {
                return current
            }
            if bestChallenger.score >= current.score {
                return bestChallenger
            }
            return current
        }

        // First boot (no previous focus): prefer attention-requiring tasks first, then most recently changed.
        if let urgent = candidates
            .filter({ $0.status.isAttentionRequired })
            .max(by: { ($0.score, $0.lastChangedAt) < ($1.score, $1.lastChangedAt) }) {
            return urgent
        }

        return candidates.max { lhs, rhs in
            if lhs.lastChangedAt != rhs.lastChangedAt {
                return lhs.lastChangedAt < rhs.lastChangedAt
            }
            return lhs.score < rhs.score
        }
    }
}
