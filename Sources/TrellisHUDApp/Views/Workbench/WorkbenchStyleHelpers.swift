import Foundation
import SwiftUI
import TrellisCore

// MARK: - Shared Native Visual Helpers

enum HUDVisuals {
    static func color(for status: RuntimeStatus) -> Color {
        switch status {
        case .waitingPermission: return .orange
        case .waitingQuestion: return .orange
        case .failed: return .red
        case .working: return .blue
        case .done: return .green
        case .stale: return .secondary
        case .idle: return .secondary
        }
    }

    static func icon(for status: RuntimeStatus) -> String {
        switch status {
        case .waitingPermission: return "hand.raised.fill"
        case .waitingQuestion: return "questionmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .working: return "bolt.fill"
        case .done: return "checkmark.circle.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .idle: return "moon.zzz"
        }
    }

    static func color(for outcome: ActivityOutcome) -> Color {
        switch outcome {
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        case .waiting: return .orange
        case .info: return .secondary
        }
    }

    static func color(for lifecycle: ChannelWorkerLifecycle) -> Color {
        switch lifecycle {
        case .starting: return .blue
        case .running: return .green
        case .done: return .secondary
        case .error, .crashed: return .red
        case .killed: return .orange
        }
    }

    static func color(for changeKind: GitChangeKind) -> Color {
        switch changeKind {
        case .added: return .green
        case .modified: return .orange
        case .deleted: return .red
        case .renamed: return .blue
        case .untracked: return .secondary
        case .conflicted: return .pink
        }
    }

    static func shortBadge(for changeKind: GitChangeKind) -> String {
        switch changeKind {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        case .conflicted: return "U"
        }
    }

    static func icon(for agent: AgentKind) -> String {
        switch agent {
        case .claude: return "sparkles"
        case .codex: return "terminal"
        case .cursor: return "cursorarrow.rays"
        case .pi: return "pi"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .dsh: return "cpu"
        case .antigravity: return "atom"
        case .unknown: return "circle.grid.2x2"
        }
    }

    static func displayName(for platform: MemoryPlatform) -> String {
        switch platform {
        case .antigravity: return "Antigravity"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .devin: return "Devin"
        case .grok: return "Grok"
        case .opencode: return "OpenCode"
        case .pi: return "Pi"
        case .zcode: return "Zcode"
        case .unknown: return "Other"
        }
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func relativeTime(_ date: Date?) -> String {
        guard let date, date != .distantPast else { return "—" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 30 { return "\(days)d ago" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func shortDate(_ date: Date?) -> String {
        guard let date, date != .distantPast else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Reusable Native Card & Pill Components

struct WorkbenchCard<Content: View>: View {
    let title: String?
    let systemImage: String?
    let trailing: AnyView?
    @ViewBuilder let content: () -> Content

    init(
        title: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = nil
        self.content = content
    }

    init<Trailing: View>(
        title: String,
        systemImage: String? = nil,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = AnyView(trailing())
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    if let trailing {
                        trailing
                    }
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 3.5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6.5)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.13), in: Capsule())
    }
}

struct EmptyStatePlaceholder: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}
