import SwiftUI
import TrellisCore

struct LiveChannelTabView: View {
    let store: HUDStore
    @State private var selectedThreadFilter: String?

    var body: some View {
        let l10n = store.l10n

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                attentionInboxSection(l10n: l10n)
                channelMonitorSection(l10n: l10n)
            }
            .padding(14)
        }
    }

    // MARK: - Top Section: Multi-Agent Attention Inbox

    private func attentionInboxSection(l10n: L10n) -> some View {
        let attention = store.activeSessions.filter { $0.status.isAttentionRequired }
        let working = store.activeSessions.filter { $0.status == .working }
        let idleOrDone = store.activeSessions.filter {
            !$0.status.isAttentionRequired && $0.status != .working
        }

        return WorkbenchCard(
            title: l10n.t("Multi-Agent Attention Inbox", "多 Agent 关注收件箱"),
            systemImage: "bell.badge.waveform"
        ) {
            HStack(spacing: 6) {
                if !attention.isEmpty {
                    StatusPill(
                        text: l10n.t("\(attention.count) Waiting", "\(attention.count) 待处理"),
                        color: .orange,
                        systemImage: "exclamationmark.circle.fill"
                    )
                }
                if !working.isEmpty {
                    StatusPill(
                        text: l10n.t("\(working.count) Working", "\(working.count) 运行中"),
                        color: .blue,
                        systemImage: "bolt.fill"
                    )
                }
                Text(l10n.t("\(store.activeSessions.count) total", "共 \(store.activeSessions.count) 个"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } content: {
            if store.activeSessions.isEmpty {
                VStack(spacing: 8) {
                    EmptyStatePlaceholder(
                        systemImage: "waveform.path.ecg",
                        title: l10n.t("No Active Agent Sessions", "暂无活跃 Agent 会话"),
                        subtitle: l10n.t(
                            "Install agent hooks in Settings to monitor Claude Code, Codex, Cursor, Pi, OpenCode, and DeepSeek Harness live.",
                            "在设置中一键安装 Agent Hook，即可实时监控 Claude Code、Codex、Cursor、Pi、OpenCode 与 DeepSeek Harness。"
                        )
                    )
                    Button(l10n.t("Configure Agent Hooks…", "配置 Agent Hook…")) {
                        store.isSettingsOpen = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if !attention.isEmpty {
                        sessionGroupHeader(l10n.t("Waiting on You & Failed", "等待你的操作 / 失败"), count: attention.count, color: .orange)
                        ForEach(attention) { session in
                            sessionRow(session, highlightAttention: true, l10n: l10n)
                        }
                    }

                    if !working.isEmpty {
                        sessionGroupHeader(l10n.t("Working", "运行中"), count: working.count, color: .blue)
                        ForEach(working) { session in
                            sessionRow(session, highlightAttention: false, l10n: l10n)
                        }
                    }

                    if !idleOrDone.isEmpty {
                        sessionGroupHeader(l10n.t("Idle & Recent", "空闲与近期"), count: idleOrDone.count, color: .secondary)
                        ForEach(idleOrDone) { session in
                            sessionRow(session, highlightAttention: false, l10n: l10n)
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
                .foregroundStyle(.secondary)
        }
    }

    private func sessionRow(_ session: AgentSessionState, highlightAttention: Bool, l10n: L10n) -> some View {
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

                    StatusPill(text: l10n.statusLabel(session.status), color: statusColor)

                    Text(projectName)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let taskId = session.taskId, !taskId.isEmpty {
                        Text("/ \(taskId)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 6) {
                    if let tool = session.toolName, !tool.isEmpty {
                        Text(tool)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.9))
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3.5))
                    }

                    Text(detail.isEmpty ? l10n.t("Active session", "活跃会话") : detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            Text(HUDVisuals.relativeTime(session.updatedAt, l10n: l10n))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            Button {
                store.jumpToSession(session)
            } label: {
                Label(l10n.t("Jump", "跳转"), systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(highlightAttention ? statusColor : nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            highlightAttention ? statusColor.opacity(0.13) : Color(nsColor: .textBackgroundColor).opacity(0.65),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    highlightAttention ? statusColor.opacity(0.4) : Color(nsColor: .separatorColor).opacity(0.45),
                    lineWidth: 0.75
                )
        )
    }

    // MARK: - Bottom Section: Live Trellis Channel Monitor

    private func channelMonitorSection(l10n: L10n) -> some View {
        WorkbenchCard(
            title: l10n.t("Trellis Channel Monitor", "Trellis Channel 实时监控"),
            systemImage: "bubble.left.and.bubble.right"
        ) {
            HStack(spacing: 8) {
                if !store.channels.isEmpty {
                    channelSelectorMenu(l10n: l10n)
                }
                Button {
                    store.refreshChannelsOnly()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(InteractiveSurfaceButtonStyle(cornerRadius: 5))
                .help(l10n.t("Reload ~/.trellis/channels/", "重新加载 ~/.trellis/channels/"))
            }
        } content: {
            if let channel = store.selectedChannel {
                channelDetailView(channel, l10n: l10n)
            } else {
                EmptyStatePlaceholder(
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    title: l10n.t("No Active Trellis Channels", "暂无活跃 Trellis 频道"),
                    subtitle: l10n.t(
                        "Multi-agent channel traffic from ~/.trellis/channels/**/events.jsonl will stream here automatically.",
                        "来自 ~/.trellis/channels/**/events.jsonl 的多 Agent 协作频道消息将自动实时展示在此。"
                    )
                )
            }
        }
    }

    private func channelSelectorMenu(l10n: L10n) -> some View {
        Menu {
            ForEach(store.channels) { ch in
                Button {
                    selectedThreadFilter = nil
                    store.selectChannel(ch.id)
                } label: {
                    HStack {
                        Text(l10n.t("\(ch.name) (\(ch.activeWorkers.count) active)", "\(ch.name) (\(ch.activeWorkers.count) 活跃)"))
                        if ch.id == store.selectedChannel?.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.selectedChannel?.name ?? l10n.t("Channel", "频道"))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func channelDetailView(_ channel: ChannelInfo, l10n: L10n) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                StatusPill(text: channel.type.rawValue.uppercased(), color: .accentColor)
                StatusPill(text: channel.scope.rawValue, color: .secondary)
                if let taskRef = channel.taskRef, !taskRef.isEmpty {
                    StatusPill(text: taskRef, color: .purple, systemImage: "link")
                }
                Spacer()
                Text("seq #\(channel.lastSeq)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if !channel.workers.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(l10n.t(
                        "Workers (\(channel.activeWorkers.count) active / \(channel.workers.count) total)",
                        "Workers（活跃 \(channel.activeWorkers.count) / 共 \(channel.workers.count)）"
                    ))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(channel.workers) { worker in
                                workerChip(worker, l10n: l10n)
                            }
                        }
                    }
                }
            }

            if !channel.threads.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(l10n.t("Threads (\(channel.threads.count))", "话题 (\(channel.threads.count))"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            threadPill(id: nil, title: l10n.t("All", "全部"), count: channel.recentMessages.count, status: nil)
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

            let visibleMessages = channel.recentMessages.filter { msg in
                guard let filter = selectedThreadFilter else { return true }
                return msg.thread == filter
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(l10n.t("Messages (\(visibleMessages.count))", "消息 (\(visibleMessages.count))"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if visibleMessages.isEmpty {
                    Text(l10n.t("No messages in this channel yet.", "该频道暂无消息。"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
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

    private func workerChip(_ worker: ChannelWorkerState, l10n: L10n) -> some View {
        let lifeColor = HUDVisuals.color(for: worker.lifecycle)
        let activityLabel = worker.activity == .midTurn
            ? l10n.t("mid-turn", "执行中")
            : l10n.t("idle", "空闲")
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
                    Text(l10n.t("\(worker.pendingMessageCount) queued", "\(worker.pendingMessageCount) 待处理"))
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
                        .foregroundStyle(.secondary)
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
        .background(Color(nsColor: .textBackgroundColor).opacity(0.68), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(lifeColor.opacity(0.35), lineWidth: 0.75)
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
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let status, status != "open" {
                    Text("· \(status)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
        }
        .buttonStyle(InteractiveSurfaceButtonStyle(
            isSelected: isSelected,
            isCapsule: true,
            baseFill: Color.primary.opacity(0.06),
            selectedFill: Color.accentColor.opacity(0.18),
            selectedBorder: Color.accentColor.opacity(0.45)
        ))
    }

    private func channelMessageRow(_ msg: ChannelMessage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("#\(msg.seq)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
            }

            if !msg.text.isEmpty {
                InlineMarkdownText(msg.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.94))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.68), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.38), lineWidth: 0.5)
        )
    }
}
