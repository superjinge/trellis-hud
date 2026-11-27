import SwiftUI
import TrellisCore

struct LiveChannelTabView: View {
    let store: HUDStore
    @State private var selectedThreadFilter: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                attentionInboxSection
                channelMonitorSection
            }
            .padding(14)
        }
    }

    // MARK: - Top Section: Multi-Agent Attention Inbox

    private var attentionInboxSection: some View {
        let attention = store.activeSessions.filter { $0.status.isAttentionRequired }
        let working = store.activeSessions.filter { $0.status == .working }
        let idleOrDone = store.activeSessions.filter {
            !$0.status.isAttentionRequired && $0.status != .working
        }

        return WorkbenchCard(
            title: "Multi-Agent Attention Inbox",
            systemImage: "bell.badge.waveform"
        ) {
            HStack(spacing: 6) {
                if !attention.isEmpty {
                    StatusPill(text: "\(attention.count) Waiting", color: .orange, systemImage: "exclamationmark.circle.fill")
                }
                if !working.isEmpty {
                    StatusPill(text: "\(working.count) Working", color: .blue, systemImage: "bolt.fill")
                }
                Text("\(store.activeSessions.count) total")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } content: {
            if store.activeSessions.isEmpty {
                VStack(spacing: 8) {
                    EmptyStatePlaceholder(
                        systemImage: "waveform.path.ecg",
                        title: "No Active Agent Sessions",
                        subtitle: "Install agent hooks in Settings to monitor Claude Code, Codex, Cursor, Pi, OpenCode, and DeepSeek Harness live."
                    )
                    Button("Configure Agent Hooks…") {
                        store.isSettingsOpen = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if !attention.isEmpty {
                        sessionGroupHeader("Waiting on You & Failed", count: attention.count, color: .orange)
                        ForEach(attention) { session in
                            sessionRow(session, highlightAttention: true)
                        }
                    }

                    if !working.isEmpty {
                        sessionGroupHeader("Working", count: working.count, color: .blue)
                        ForEach(working) { session in
                            sessionRow(session, highlightAttention: false)
                        }
                    }

                    if !idleOrDone.isEmpty {
                        sessionGroupHeader("Idle & Recent", count: idleOrDone.count, color: .secondary)
                        ForEach(idleOrDone) { session in
                            sessionRow(session, highlightAttention: false)
                        }
                    }
                }
            }
        }
    }

    private func sessionGroupHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(color)
                .textCase(.uppercase)
            Text("· \(count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func sessionRow(_ session: AgentSessionState, highlightAttention: Bool) -> some View {
        let statusColor = HUDVisuals.color(for: session.status)
        let projectName = URL(fileURLWithPath: session.projectPath).lastPathComponent
        let detail = session.activity?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? session.activity!
            : (session.toolInput?.filePath ?? session.toolInput?.command ?? session.toolName ?? session.eventName)

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: HUDVisuals.icon(for: session.status))
                .font(.system(size: 13))
                .foregroundStyle(statusColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.agent.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    StatusPill(text: session.status.label, color: statusColor)

                    Text(projectName)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let taskId = session.taskId, !taskId.isEmpty {
                        Text("/ \(taskId)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 6) {
                    if let tool = session.toolName, !tool.isEmpty {
                        Text(tool)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.85))
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3.5))
                    }

                    Text(detail.isEmpty ? "Active session" : detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            Text(HUDVisuals.relativeTime(session.updatedAt))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)

            Button {
                store.jumpToSession(session)
            } label: {
                Label("Jump", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(highlightAttention ? statusColor : nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            highlightAttention ? statusColor.opacity(0.1) : Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    highlightAttention ? statusColor.opacity(0.32) : Color.primary.opacity(0.06),
                    lineWidth: 0.75
                )
        )
    }

    // MARK: - Bottom Section: Live Trellis Channel Monitor

    private var channelMonitorSection: some View {
        WorkbenchCard(
            title: "Trellis Channel Monitor",
            systemImage: "bubble.left.and.bubble.right"
        ) {
            HStack(spacing: 8) {
                if !store.channels.isEmpty {
                    channelSelectorMenu
                }
                Button {
                    store.refreshChannelsOnly()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reload ~/.trellis/channels/")
            }
        } content: {
            if let channel = store.selectedChannel {
                channelDetailView(channel)
            } else {
                EmptyStatePlaceholder(
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    title: "No Active Trellis Channels",
                    subtitle: "Multi-agent channel traffic from ~/.trellis/channels/**/events.jsonl will stream here automatically."
                )
            }
        }
    }

    private var channelSelectorMenu: some View {
        Menu {
            ForEach(store.channels) { ch in
                Button {
                    selectedThreadFilter = nil
                    store.selectChannel(ch.id)
                } label: {
                    HStack {
                        Text("\(ch.name) (\(ch.activeWorkers.count) active)")
                        if ch.id == store.selectedChannel?.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.selectedChannel?.name ?? "Channel")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func channelDetailView(_ channel: ChannelInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Channel metadata strip
            HStack(spacing: 6) {
                StatusPill(text: channel.type.rawValue.uppercased(), color: .accentColor)
                StatusPill(text: channel.scope.rawValue, color: .secondary)
                if let taskRef = channel.taskRef, !taskRef.isEmpty {
                    StatusPill(text: taskRef, color: .purple, systemImage: "link")
                }
                Spacer()
                Text("seq #\(channel.lastSeq)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // Active & recent workers
            if !channel.workers.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Workers (\(channel.activeWorkers.count) active / \(channel.workers.count) total)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(channel.workers) { worker in
                                workerChip(worker)
                            }
                        }
                    }
                }
            }

            // Threads filter strip (forum or threaded chat)
            if !channel.threads.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Threads (\(channel.threads.count))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            threadPill(id: nil, title: "All", count: channel.recentMessages.count, status: nil)
                            ForEach(channel.threads) { thread in
                                threadPill(
                                    id: thread.thread,
                                    title: thread.title ?? thread.thread,
                                    count: thread.comments,
                                    status: thread.status
                                )
                            }
                        }
                    }
                }
            }

            // Live Message Stream
            let visibleMessages = channel.recentMessages.filter { msg in
                guard let filter = selectedThreadFilter else { return true }
                return msg.thread == filter
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Messages (\(visibleMessages.count))")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if visibleMessages.isEmpty {
                    Text("No messages in this channel yet.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 6)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(visibleMessages.suffix(30).reversed()) { msg in
                            channelMessageRow(msg)
                        }
                    }
                }
            }
        }
    }

    private func workerChip(_ worker: ChannelWorkerState) -> some View {
        let lifeColor = HUDVisuals.color(for: worker.lifecycle)
        let activityLabel = worker.activity == .midTurn ? "mid-turn" : "idle"
        let activityColor: Color = worker.activity == .midTurn ? .blue : .secondary

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(lifeColor)
                    .frame(width: 6.5, height: 6.5)
                Text(worker.workerId)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                if worker.pendingMessageCount > 0 {
                    Text("\(worker.pendingMessageCount) queued")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 4) {
                StatusPill(text: worker.lifecycle.rawValue, color: lifeColor)
                if !worker.isTerminal {
                    StatusPill(text: activityLabel, color: activityColor)
                }
                if let agent = worker.agent, !agent.isEmpty {
                    Text(agent)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if let err = worker.lastError, !err.isEmpty {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6.5)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(lifeColor.opacity(0.24), lineWidth: 0.75)
        )
    }

    private func threadPill(id: String?, title: String, count: Int, status: String?) -> some View {
        let isSelected = selectedThreadFilter == id
        return Button {
            selectedThreadFilter = id
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let status, status != "open" {
                    Text("· \(status)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
    }

    private func channelMessageRow(_ msg: ChannelMessage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("#\(msg.seq)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(msg.by)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                if !msg.to.isEmpty {
                    Text("→ \(msg.to.joined(separator: ", "))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
                if let thread = msg.thread, !thread.isEmpty {
                    StatusPill(text: thread, color: .secondary)
                }
                Spacer()
                Text(HUDVisuals.shortTime(msg.timestamp))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if !msg.text.isEmpty {
                InlineMarkdownText(msg.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
