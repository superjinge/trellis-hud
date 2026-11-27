import SwiftUI
import TrellisCore

struct FlowTabView: View {
    let store: HUDStore

    @State private var expandedChecklistGroups: Set<String> = ["implement.md", "prd.md"]
    @State private var showActionOutput = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let task = store.selectedTask {
                        pipelineCard(task: task)
                        checklistOrArtifactCard(task: task)
                    } else {
                        noTaskCard
                    }

                    gitAndSpecCard
                    activityTraceCard
                }
                .padding(14)
            }

            if let result = store.lastActionResult, showActionOutput {
                actionOutputDrawer(result)
            }

            Divider().opacity(0.45)
            humanGateActionBar
        }
    }

    // MARK: - No Task Empty State

    private var noTaskCard: some View {
        WorkbenchCard {
            EmptyStatePlaceholder(
                systemImage: "tray",
                title: store.selectedProject == nil ? "No Watched Project" : "No Active Trellis Task",
                subtitle: store.selectedProject == nil
                    ? "Open Settings to add a folder containing .trellis projects."
                    : "Start a task in \(store.selectedProject?.name ?? "your repo") with trellis task create, or inspect Git & Specs below."
            )
        }
    }

    // MARK: - 5-Step Real Workflow Pipeline

    private func pipelineCard(task: TaskSnapshot) -> some View {
        WorkbenchCard(
            title: "Workflow Pipeline",
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
                                        ? Color.green.opacity(0.18)
                                        : (isCurrent ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
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

                        Text(phase.label)
                            .font(.system(size: 11.5, weight: isCurrent ? .semibold : .medium))
                            .foregroundStyle(isCurrent ? .primary : (isDoneStep ? .secondary : .tertiary))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        isCurrent ? Color.accentColor.opacity(0.1) : Color.clear,
                        in: Capsule()
                    )

                    if idx < WorkflowPhase.allCases.count - 1 {
                        Rectangle()
                            .fill(isDoneStep ? Color.green.opacity(0.4) : Color.primary.opacity(0.1))
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
                        .foregroundStyle(.primary.opacity(0.85))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            }

            // Honest artifact gate readiness row
            HStack(spacing: 6) {
                artifactChip("PRD", ready: task.artifacts.hasPrd)
                artifactChip("Design", ready: task.artifacts.hasDesign)
                artifactChip("Implement", ready: task.artifacts.hasImplement)
                if task.artifacts.researchCount > 0 {
                    StatusPill(text: "Research ×\(task.artifacts.researchCount)", color: .secondary)
                }
                if task.artifacts.implContextCount > 0 {
                    StatusPill(text: "Impl Ctx \(task.artifacts.implContextCount)", color: .secondary)
                }
                if task.artifacts.checkContextCount > 0 {
                    StatusPill(text: "Check Ctx \(task.artifacts.checkContextCount)", color: .secondary)
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

    private func checklistOrArtifactCard(task: TaskSnapshot) -> some View {
        let total = task.totalChecklistCount
        let done = task.completedChecklistCount

        return WorkbenchCard(
            title: total > 0 ? "Checklist Progress" : "Task Artifacts & Subtasks",
            systemImage: total > 0 ? "checklist" : "doc.text"
        ) {
            if total > 0 {
                Text("\(done) / \(total) completed")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(done == total ? Color.green : Color.primary)
            } else {
                Text("No markdown checkboxes yet")
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
                                                    .foregroundStyle(.tertiary)
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
                        }
                    }
                }
            } else {
                // Honest artifact & subtask overview — never fabricate a fake percentage
                VStack(alignment: .leading, spacing: 6) {
                    if !task.artifacts.documentPaths.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(task.artifacts.documentPaths.prefix(5), id: \.self) { docPath in
                                Button {
                                    store.loadDocument(docPath)
                                    store.selectedTab = .docsSpecs
                                } label: {
                                    StatusPill(text: docPath, color: .accentColor, systemImage: "doc.plaintext")
                                }
                                .buttonStyle(.plain)
                            }
                            if task.artifacts.documentPaths.count > 5 {
                                Text("+\(task.artifacts.documentPaths.count - 5)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Add `- [ ]` acceptance criteria in prd.md or implement.md to track checklist progress here.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    if !task.record.subtasks.isEmpty {
                        Divider().opacity(0.4)
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

    // MARK: - Git & Spec Governance Card

    private var gitAndSpecCard: some View {
        let git = store.gitStatus
        let uncoveredCount = store.uncoveredModifiedFiles.count

        return WorkbenchCard(
            title: "Git & Spec Governance",
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
                        StatusPill(text: "Worktree", color: .purple)
                    }
                    if git.ahead > 0 || git.behind > 0 {
                        StatusPill(text: "↑\(git.ahead) ↓\(git.behind)", color: .secondary)
                    }
                    StatusPill(
                        text: git.isClean ? "Clean" : "\(git.changes.count) dirty",
                        color: git.isClean ? .green : .orange
                    )
                } else {
                    Text("No git status")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        } content: {
            if let git {
                if uncoveredCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text("\(uncoveredCount) modified \(uncoveredCount == 1 ? "file has" : "files have") zero .trellis/spec/ coverage")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.9))
                        Spacer()
                        Button("Inspect Specs") {
                            store.selectedTab = .docsSpecs
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .buttonStyle(.link)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                }

                if git.changes.isEmpty {
                    Text("Working tree is clean. All changes committed.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(git.changes.prefix(12)) { change in
                            let matchedSpecs = store.specsForModifiedFile(change.path)
                            HStack(alignment: .center, spacing: 6) {
                                Text(HUDVisuals.shortBadge(for: change.kind))
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(HUDVisuals.color(for: change.kind))
                                    .frame(width: 15, height: 15)
                                    .background(HUDVisuals.color(for: change.kind).opacity(0.14), in: RoundedRectangle(cornerRadius: 3.5))

                                Text(change.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer(minLength: 6)

                                if matchedSpecs.isEmpty {
                                    StatusPill(text: "No spec", color: .orange)
                                } else {
                                    HStack(spacing: 4) {
                                        ForEach(matchedSpecs.prefix(2)) { spec in
                                            Button {
                                                store.selectSpec(spec.relativePath)
                                                store.selectedTab = .docsSpecs
                                            } label: {
                                                StatusPill(text: spec.name, color: .green, systemImage: "checkmark.shield")
                                            }
                                            .buttonStyle(.plain)
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
                            Text("…and \(git.changes.count - 12) more modified files")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                    }
                }
            } else {
                Text("Select a Git repository to inspect branch state and .trellis/spec/ coverage.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Chronological Tool / Activity Trace

    private var activityTraceCard: some View {
        let entries = Array(store.currentTaskActivities.prefix(12))

        return WorkbenchCard(
            title: "Recent Activity Trace",
            systemImage: "list.bullet.rectangle"
        ) {
            Text("\(store.currentTaskActivities.count) events")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
        } content: {
            if entries.isEmpty {
                Text("No live tool events yet. Hook events from Claude Code, Codex, Cursor, Pi, OpenCode, or DSH appear here in real time.")
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
                                .foregroundStyle(.tertiary)

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
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                            }

                            Text(entry.targetPath.map { "\($0) — \(entry.summary)" } ?? entry.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.86))
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

    private func actionOutputDrawer(_ result: ActionResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(result.success ? Color.green : Color.red)
                Text("\(result.action.rawValue.capitalized) (\(result.durationMs)ms · exit \(result.exitCode))")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                Spacer()
                Button {
                    showActionOutput = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            let combined = [result.message, result.stdout, result.stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !combined.isEmpty {
                ScrollView {
                    Text(combined)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 84)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.045))
    }

    private var humanGateActionBar: some View {
        HStack(spacing: 8) {
            Button {
                store.jumpToTerminal()
            } label: {
                Label("Jump to Terminal", systemImage: "terminal")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer(minLength: 4)

            if store.lastActionResult != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showActionOutput.toggle()
                    }
                } label: {
                    Image(systemName: showActionOutput ? "chevron.down.square" : "doc.text.magnifyingglass")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Toggle last command output")
            }

            gateActionButton(title: "Validate", icon: "checkmark.shield", action: .validate) {
                showActionOutput = true
                store.runValidate()
            }
            gateActionButton(title: "Start", icon: "play.fill", action: .start) {
                showActionOutput = true
                store.runStartTask()
            }
            gateActionButton(title: "Archive", icon: "archivebox", action: .archive, prominent: true) {
                showActionOutput = true
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

    private func priorityColor(_ priority: String) -> Color {
        switch priority.uppercased() {
        case "P0": return .red
        case "P1": return .orange
        case "P2": return .blue
        default: return .secondary
        }
    }
}
