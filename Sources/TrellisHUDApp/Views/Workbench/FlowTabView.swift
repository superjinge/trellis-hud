import SwiftUI
import TrellisCore

struct FlowTabView: View {
    let store: HUDStore

    @State private var expandedChecklistGroups: Set<String> = ["implement.md", "prd.md"]
    @State private var showActionOutput = false

    var body: some View {
        let l10n = store.l10n

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let task = store.selectedTask {
                        pipelineCard(task: task, l10n: l10n)
                        checklistOrArtifactCard(task: task, l10n: l10n)
                    } else {
                        noTaskCard(l10n: l10n)
                    }

                    gitAndSpecCard(l10n: l10n)
                    activityTraceCard(l10n: l10n)
                }
                .padding(14)
            }

            if let running = store.runningAction {
                runningActionDrawer(running, l10n: l10n)
            } else if let result = store.lastActionResult, showActionOutput {
                actionOutputDrawer(result, l10n: l10n)
            }

            Divider().opacity(0.55)
            humanGateActionBar(l10n: l10n)
        }
        .onChange(of: store.lastActionResult) { _, newValue in
            if newValue != nil {
                showActionOutput = true
            }
        }
    }

    // MARK: - No Task Empty State

    private func noTaskCard(l10n: L10n) -> some View {
        WorkbenchCard {
            EmptyStatePlaceholder(
                systemImage: "tray",
                title: store.selectedProject == nil
                    ? l10n.t("No Watched Project", "暂无监听项目")
                    : l10n.t("No Active Trellis Task", "暂无进行中的 Trellis 任务"),
                subtitle: store.selectedProject == nil
                    ? l10n.t(
                        "Open Settings to add a folder containing .trellis projects.",
                        "请打开设置添加包含 .trellis 项目的文件夹。"
                    )
                    : l10n.t(
                        "Start a task in \(store.selectedProject?.name ?? "your repo") with trellis task create, or inspect Git & Specs below.",
                        "在 \(store.selectedProject?.name ?? "当前仓库") 中运行 trellis task create 创建任务，或在下方查看 Git 与规范状态。"
                    )
            )
        }
    }

    // MARK: - 5-Step Real Workflow Pipeline

    private func pipelineCard(task: TaskSnapshot, l10n: L10n) -> some View {
        WorkbenchCard(
            title: l10n.t("Workflow Pipeline", "工作流阶段"),
            systemImage: "point.3.connected.trianglepath.dotted"
        ) {
            HStack(spacing: 6) {
                StatusPill(text: task.record.priority, color: priorityColor(task.record.priority))
                StatusPill(text: task.record.status, color: task.isDone ? .green : .blue)
                if let pkg = task.record.package, !pkg.isEmpty {
                    StatusPill(text: pkg, color: .secondary)
                }
            }
        } content: {
            HStack(spacing: 0) {
                ForEach(Array(WorkflowPhase.allCases.enumerated()), id: \.element) { idx, phase in
                    let isDoneStep = task.isDone || phase.order < task.phase.order
                    let isCurrent = !task.isDone && phase == task.phase

                    HStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .fill(
                                    isDoneStep
                                        ? Color.green.opacity(0.2)
                                        : (isCurrent ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.08))
                                )
                                .frame(width: 20, height: 20)
                            if isDoneStep {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.green)
                            } else {
                                Text("\(idx + 1)")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                            }
                        }

                        Text(l10n.phaseLabel(phase))
                            .font(.system(size: 11.5, weight: isCurrent ? .semibold : .medium))
                            .foregroundStyle(isCurrent ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        isCurrent ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: Capsule()
                    )

                    if idx < WorkflowPhase.allCases.count - 1 {
                        Rectangle()
                            .fill(isDoneStep ? Color.green.opacity(0.45) : Color.primary.opacity(0.14))
                            .frame(height: 1)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 2)
                    }
                }
            }

            if let warning = task.phaseWarning, !warning.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.9))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }

            HStack(spacing: 6) {
                artifactChip(l10n.t("PRD", "需求 PRD"), ready: task.artifacts.hasPrd)
                artifactChip(l10n.t("Design", "设计"), ready: task.artifacts.hasDesign)
                artifactChip(l10n.t("Implement", "实施"), ready: task.artifacts.hasImplement)
                if task.artifacts.researchCount > 0 {
                    StatusPill(text: l10n.t("Research ×\(task.artifacts.researchCount)", "调研 ×\(task.artifacts.researchCount)"), color: .secondary)
                }
                if task.artifacts.implContextCount > 0 {
                    StatusPill(text: l10n.t("Impl Ctx \(task.artifacts.implContextCount)", "实施上下文 \(task.artifacts.implContextCount)"), color: .secondary)
                }
                if task.artifacts.checkContextCount > 0 {
                    StatusPill(text: l10n.t("Check Ctx \(task.artifacts.checkContextCount)", "校验上下文 \(task.artifacts.checkContextCount)"), color: .secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func artifactChip(_ name: String, ready: Bool) -> some View {
        StatusPill(
            text: name,
            color: ready ? .green : .secondary,
            systemImage: ready ? "checkmark.circle.fill" : "circle.dashed"
        )
    }

    // MARK: - Real Markdown Checklist Progress (or Honest Artifact Readiness)

    private func checklistOrArtifactCard(task: TaskSnapshot, l10n: L10n) -> some View {
        let total = task.totalChecklistCount
        let done = task.completedChecklistCount

        return WorkbenchCard(
            title: total > 0
                ? l10n.t("Checklist Progress", "清单完成进度")
                : l10n.t("Task Artifacts & Subtasks", "任务文档与子任务"),
            systemImage: total > 0 ? "checklist" : "doc.text"
        ) {
            if total > 0 {
                Text(l10n.t("\(done) / \(total) completed", "已完成 \(done) / \(total)"))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(done == total ? Color.green : Color.primary)
            } else {
                Text(l10n.t("No markdown checkboxes yet", "暂无 Markdown 复选框"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } content: {
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .tint(done == total ? .green : .accentColor)

                let grouped = Dictionary(grouping: task.checklist, by: \.sourceFile)
                let sortedKeys = grouped.keys.sorted()

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sortedKeys, id: \.self) { file in
                        let items = grouped[file] ?? []
                        let groupDone = items.filter(\.isCompleted).count
                        let isExpanded = Binding<Bool>(
                            get: { expandedChecklistGroups.contains(file) },
                            set: { newVal in
                                if newVal { expandedChecklistGroups.insert(file) }
                                else { expandedChecklistGroups.remove(file) }
                            }
                        )

                        DisclosureGroup(isExpanded: isExpanded) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(items) { item in
                                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                                        Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(item.isCompleted ? Color.green : Color.secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            InlineMarkdownText(item.text)
                                                .font(.system(size: 11.5))
                                                .strikethrough(item.isCompleted, color: .secondary.opacity(0.6))
                                                .foregroundStyle(item.isCompleted ? .secondary : .primary)
                                            if let sec = item.section, !sec.isEmpty {
                                                Text("\(sec) · L\(item.lineNumber)")
                                                    .font(.system(size: 9.5, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 1)
                                }
                            }
                            .padding(.top, 4)
                            .padding(.leading, 4)
                        } label: {
                            HStack(spacing: 6) {
                                Text(file)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Text("\(groupDone)/\(items.count)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if !task.artifacts.documentPaths.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(task.artifacts.documentPaths.prefix(5), id: \.self) { docPath in
                                Button {
                                    store.loadDocument(docPath)
                                    store.docsSubMode = .taskDocs
                                    store.selectedTab = .docsSpecs
                                } label: {
                                    StatusPill(text: docPath, color: .accentColor, systemImage: "doc.plaintext")
                                }
                                .buttonStyle(InteractiveSurfaceButtonStyle(isCapsule: true))
                            }
                            if task.artifacts.documentPaths.count > 5 {
                                Text("+\(task.artifacts.documentPaths.count - 5)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(l10n.t(
                            "Add `- [ ]` acceptance criteria in prd.md or implement.md to track checklist progress here.",
                            "在 prd.md 或 implement.md 中添加 `- [ ]` 验收项即可在此追踪真实进度。"
                        ))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    }

                    if !task.record.subtasks.isEmpty {
                        Divider().opacity(0.45)
                        ForEach(Array(task.record.subtasks.enumerated()), id: \.offset) { _, sub in
                            HStack(spacing: 6) {
                                Image(systemName: sub.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(sub.isCompleted ? .green : .secondary)
                                Text(sub.name)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(sub.isCompleted ? .secondary : .primary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Git Changes & Specs Card (Precomputed O(1) Lookup)

    private func gitAndSpecCard(l10n: L10n) -> some View {
        let git = store.gitStatus
        let specsByModifiedFile: [String: [SpecDocument]] = {
            var map: [String: [SpecDocument]] = [:]
            for spec in store.specs {
                for path in spec.matchedModifiedFiles {
                    map[path, default: []].append(spec)
                }
            }
            return map
        }()

        return WorkbenchCard(
            title: l10n.t("Git Changes & Specs", "Git 改动与关联规范"),
            systemImage: "arrow.triangle.branch"
        ) {
            HStack(spacing: 6) {
                if let git {
                    if let branch = git.branch {
                        StatusPill(
                            text: git.isDetachedHead ? "HEAD \(branch)" : branch,
                            color: .primary,
                            systemImage: "arrow.triangle.branch"
                        )
                    }
                    if git.isWorktree {
                        StatusPill(text: l10n.t("Worktree", "工作树"), color: .purple)
                    }
                    if git.ahead > 0 || git.behind > 0 {
                        StatusPill(text: "↑\(git.ahead) ↓\(git.behind)", color: .secondary)
                    }
                    StatusPill(
                        text: git.isClean
                            ? l10n.t("Clean", "干净")
                            : l10n.t("\(git.changes.count) dirty", "\(git.changes.count) 处改动"),
                        color: git.isClean ? .green : .orange
                    )
                } else {
                    Text(l10n.t("No git status", "无 Git 状态"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
        } content: {
            if let git {
                if git.changes.isEmpty {
                    Text(l10n.t("Working tree is clean. All changes committed.", "工作区干净，所有改动均已提交。"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(git.changes.prefix(12)) { change in
                            let matchedSpecs = specsByModifiedFile[change.path] ?? []
                            HStack(alignment: .center, spacing: 6) {
                                Text(HUDVisuals.shortBadge(for: change.kind))
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(HUDVisuals.color(for: change.kind))
                                    .frame(width: 15, height: 15)
                                    .background(HUDVisuals.color(for: change.kind).opacity(0.16), in: RoundedRectangle(cornerRadius: 3.5))

                                Text(change.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer(minLength: 6)

                                if !matchedSpecs.isEmpty {
                                    HStack(spacing: 4) {
                                        ForEach(matchedSpecs.prefix(2)) { spec in
                                            Button {
                                                store.openSpecInDocsTab(spec.relativePath)
                                            } label: {
                                                StatusPill(text: spec.name, color: .green, systemImage: "checkmark.shield")
                                            }
                                            .buttonStyle(InteractiveSurfaceButtonStyle(isCapsule: true))
                                        }
                                        if matchedSpecs.count > 2 {
                                            Text("+\(matchedSpecs.count - 2)")
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        if git.changes.count > 12 {
                            Text(l10n.t(
                                "…and \(git.changes.count - 12) more modified files",
                                "…以及其余 \(git.changes.count - 12) 个改动文件"
                            ))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        }
                    }
                }
            } else {
                Text(l10n.t(
                    "Select a Git repository to inspect branch changes and related specs.",
                    "选择 Git 仓库以查看分支改动与关联规范。"
                ))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Chronological Tool / Activity Trace

    private func activityTraceCard(l10n: L10n) -> some View {
        let entries = Array(store.currentTaskActivities.prefix(12))

        return WorkbenchCard(
            title: l10n.t("Recent Activity Trace", "最近工具与活动轨迹"),
            systemImage: "list.bullet.rectangle"
        ) {
            Text(l10n.t("\(store.currentTaskActivities.count) events", "\(store.currentTaskActivities.count) 条事件"))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
        } content: {
            if entries.isEmpty {
                Text(l10n.t(
                    "No live tool events yet. Hook events from Claude Code, Codex, Cursor, Pi, OpenCode, or DSH appear here in real time.",
                    "暂无实时工具事件。来自 Claude Code、Codex、Cursor、Pi、OpenCode 或 DSH 的 Hook 事件将实时显示在此。"
                ))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(entries) { entry in
                        HStack(alignment: .center, spacing: 7) {
                            Circle()
                                .fill(HUDVisuals.color(for: entry.outcome))
                                .frame(width: 6.5, height: 6.5)

                            Text(HUDVisuals.shortTime(entry.timestamp))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Image(systemName: HUDVisuals.icon(for: entry.agent))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 14)

                            if let tool = entry.toolName, !tool.isEmpty {
                                Text(tool)
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                            }

                            Text(entry.targetPath.map { "\($0) — \(entry.summary)" } ?? entry.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Action Output Drawer & Human-Gate Action Bar

    private func runningActionDrawer(_ action: ActionKind, l10n: L10n) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            Text(l10n.t("Running \(action.rawValue)…", "正在执行 \(actionLabel(action, l10n: l10n))…"))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
    }

    private func actionOutputDrawer(_ result: ActionResult, l10n: L10n) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(result.success ? Color.green : Color.red)
                Text("\(actionLabel(result.action, l10n: l10n)) (\(result.durationMs)ms · exit \(result.exitCode))")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                Spacer()
                Button {
                    showActionOutput = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(InteractiveSurfaceButtonStyle(cornerRadius: 4))
            }
            let combined = [result.message, result.stdout, result.stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !combined.isEmpty {
                ScrollView {
                    Text(combined)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 84)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.92))
    }

    private func humanGateActionBar(l10n: L10n) -> some View {
        HStack(spacing: 8) {
            Button {
                store.jumpToTerminal()
            } label: {
                Label(l10n.t("Jump to Terminal", "跳转终端"), systemImage: "terminal")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer(minLength: 4)

            if store.lastActionResult != nil && store.runningAction == nil {
                Button {
                    showActionOutput.toggle()
                } label: {
                    Image(systemName: showActionOutput ? "chevron.down.square" : "doc.text.magnifyingglass")
                        .font(.system(size: 11.5))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(InteractiveSurfaceButtonStyle(cornerRadius: 5))
                .help(l10n.t("Toggle last command output", "展开/收起上次命令输出"))
            }

            gateActionButton(title: l10n.t("Validate", "校验"), icon: "checkmark.shield", action: .validate) {
                store.runValidate()
            }
            gateActionButton(title: l10n.t("Start", "激活"), icon: "play.fill", action: .start) {
                store.runStartTask()
            }
            gateActionButton(title: l10n.t("Archive", "归档"), icon: "archivebox", action: .archive, prominent: true) {
                store.runArchiveTask()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func gateActionButton(
        title: String,
        icon: String,
        action: ActionKind,
        prominent: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        let isRunningThis = store.runningAction == action
        let isDisabled = store.runningAction != nil || store.selectedTask == nil

        let label = HStack(spacing: 5) {
            if isRunningThis {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 10.5))
            }
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
        }

        if prominent {
            Button(action: perform) { label }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isDisabled)
        } else {
            Button(action: perform) { label }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDisabled)
        }
    }

    private func actionLabel(_ action: ActionKind, l10n: L10n) -> String {
        switch action {
        case .validate: return l10n.t("Validate", "校验")
        case .start: return l10n.t("Start", "激活")
        case .archive: return l10n.t("Archive", "归档")
        case .interruptWorker: return l10n.t("Interrupt", "中断")
        case .killWorker: return l10n.t("Kill", "终止")
        case .custom: return l10n.t("Command", "命令")
        }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority.uppercased() {
        case "P0": return .red
        case "P1": return .orange
        case "P2": return .blue
        default: return .secondary
        }
    }
}
