import SwiftUI
import TrellisCore

struct HistoryTabView: View {
    let store: HUDStore

    private enum SourceFilter: String, CaseIterable, Identifiable {
        case all
        case archived
        case journals
        case mem
        var id: String { rawValue }

        func title(_ l10n: L10n) -> String {
            switch self {
            case .all: return l10n.t("All", "全部")
            case .archived: return l10n.t("Archived Tasks", "已归档任务")
            case .journals: return l10n.t("Journals", "日志")
            case .mem: return l10n.t("Mem Sessions", "会话记忆")
            }
        }
    }

    private enum HistorySelection: Hashable {
        case archived(String)
        case journal(String)
        case memory(String)
    }

    @State private var searchText: String = ""
    @State private var sourceFilter: SourceFilter = .all
    @State private var platformFilter: MemoryPlatform? = nil
    @State private var selection: HistorySelection? = nil

    var body: some View {
        let l10n = store.l10n

        VStack(spacing: 0) {
            filterHeader(l10n: l10n)
            Divider().opacity(0.55)

            HStack(spacing: 0) {
                historyListPane(l10n: l10n)
                    .frame(width: 265)
                Divider().opacity(0.55)
                historyPreviewPane(l10n: l10n)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if searchText != store.historyQuery {
                searchText = store.historyQuery
            }
            store.refreshHistoryIfNeeded()
            ensureValidSelection()
        }
        .onChange(of: store.archivedTasks) { _, _ in ensureValidSelection() }
        .onChange(of: store.journals) { _, _ in ensureValidSelection() }
        .onChange(of: store.memorySessions) { _, _ in ensureValidSelection() }
    }

    // MARK: - Search + Source + Platform Filter Bar

    private func filterHeader(l10n: L10n) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField(
                        l10n.t(
                            "Search archived tasks, journals, and trellis mem…",
                            "搜索已归档任务、开发日志与 trellis mem 会话…"
                        ),
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onChange(of: searchText) { _, newValue in
                        store.searchHistory(newValue)
                    }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            store.searchHistory("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(InteractiveSurfaceButtonStyle(cornerRadius: 4))
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5.5)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.75)
                )

                if sourceFilter == .all || sourceFilter == .mem {
                    Menu {
                        Button {
                            platformFilter = nil
                        } label: {
                            HStack {
                                Text(l10n.t("All Platforms", "全部平台"))
                                if platformFilter == nil { Image(systemName: "checkmark") }
                            }
                        }
                        Divider()
                        ForEach(MemoryPlatform.allCases.filter { $0 != .unknown }, id: \.self) { platform in
                            Button {
                                platformFilter = platform
                            } label: {
                                HStack {
                                    Text(HUDVisuals.displayName(for: platform, l10n: l10n))
                                    if platformFilter == platform { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 11))
                            Text(platformFilter.map { HUDVisuals.displayName(for: $0, l10n: l10n) } ?? l10n.t("Platform", "平台"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(platformFilter == nil ? Color.primary.opacity(0.8) : Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Button {
                    store.refreshHistory()
                } label: {
                    Group {
                        if store.isLoadingHistory {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                    }
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(InteractiveSurfaceButtonStyle(cornerRadius: 6, baseFill: Color.primary.opacity(0.06)))
                .disabled(store.isLoadingHistory)
                .help(l10n.t("Refresh history", "刷新历史记录"))
            }

            HStack(spacing: 5) {
                ForEach(SourceFilter.allCases) { filter in
                    let isSelected = sourceFilter == filter
                    Button {
                        sourceFilter = filter
                        ensureValidSelection()
                    } label: {
                        HStack(spacing: 4) {
                            Text(filter.title(l10n))
                                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            Text("\(countFor(filter))")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(InteractiveSurfaceButtonStyle(
                        isSelected: isSelected,
                        isCapsule: true,
                        selectedFill: Color.primary.opacity(0.13)
                    ))
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Filtered Collections

    private var normalizedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredArchived: [TaskSnapshot] {
        let q = normalizedQuery
        guard !q.isEmpty else { return store.archivedTasks }
        return store.archivedTasks.filter { task in
            task.record.title.lowercased().contains(q)
                || task.dir.lowercased().contains(q)
                || task.record.description.lowercased().contains(q)
                || task.excerpt.lowercased().contains(q)
        }
    }

    private var filteredJournals: [WorkspaceJournal] {
        let q = normalizedQuery
        guard !q.isEmpty else { return store.journals }
        return store.journals.filter { j in
            j.developer.lowercased().contains(q)
                || j.fileName.lowercased().contains(q)
                || (j.latestHeading?.lowercased().contains(q) ?? false)
                || j.preview.lowercased().contains(q)
                || j.content.lowercased().contains(q)
        }
    }

    private var filteredMemory: [MemorySessionItem] {
        store.memorySessions.filter { item in
            if let pf = platformFilter, item.platform != pf {
                return false
            }
            let q = normalizedQuery
            guard !q.isEmpty else { return true }
            return (item.title?.lowercased().contains(q) ?? false)
                || item.id.lowercased().contains(q)
                || (item.cwd?.lowercased().contains(q) ?? false)
                || item.excerpts.contains(where: { $0.snippet.lowercased().contains(q) })
        }
    }

    private func countFor(_ filter: SourceFilter) -> Int {
        switch filter {
        case .all:
            return filteredArchived.count + filteredJournals.count + filteredMemory.count
        case .archived:
            return filteredArchived.count
        case .journals:
            return filteredJournals.count
        case .mem:
            return filteredMemory.count
        }
    }

    // MARK: - Left Pane List

    private func historyListPane(l10n: L10n) -> some View {
        let showArchived = sourceFilter == .all || sourceFilter == .archived
        let showJournals = sourceFilter == .all || sourceFilter == .journals
        let showMem = sourceFilter == .all || sourceFilter == .mem

        let hasAny = (showArchived && !filteredArchived.isEmpty)
            || (showJournals && !filteredJournals.isEmpty)
            || (showMem && !filteredMemory.isEmpty)

        return Group {
            if store.isLoadingHistory && !hasAny {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(l10n.t("Loading history…", "正在加载历史记录…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasAny {
                EmptyStatePlaceholder(
                    systemImage: "clock.arrow.circlepath",
                    title: l10n.t("No Matching History", "暂无匹配的历史记录"),
                    subtitle: l10n.t(
                        "Try a broader search term or switch source / platform filters.",
                        "请尝试更宽泛的关键词，或切换来源与平台筛选。"
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if showArchived && !filteredArchived.isEmpty {
                            let grouped = Dictionary(grouping: filteredArchived) { archiveMonth(for: $0, l10n: l10n) }
                            let months = grouped.keys.sorted(by: >)
                            ForEach(months, id: \.self) { month in
                                sectionHeader(l10n.t("Archived · \(month)", "归档 · \(month)"), count: grouped[month]?.count ?? 0)
                                ForEach(grouped[month] ?? []) { task in
                                    archivedRow(task, l10n: l10n)
                                }
                            }
                        }

                        if showJournals && !filteredJournals.isEmpty {
                            sectionHeader(l10n.t("Workspace Journals", "开发日志"), count: filteredJournals.count)
                            ForEach(filteredJournals) { journal in
                                journalRow(journal, l10n: l10n)
                            }
                        }

                        if showMem && !filteredMemory.isEmpty {
                            sectionHeader(l10n.t("Trellis Mem Sessions", "Trellis Mem 会话"), count: filteredMemory.count)
                            ForEach(filteredMemory) { session in
                                memoryRow(session, l10n: l10n)
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            Text("\(count)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    private func archivedRow(_ task: TaskSnapshot, l10n: L10n) -> some View {
        let isSelected = selection == .archived(task.id)
        return Button {
            selection = .archived(task.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(task.record.title.isEmpty ? task.dir : task.record.title)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: task.dir).lastPathComponent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if !task.artifacts.documentPaths.isEmpty {
                        Text("\(task.artifacts.documentPaths.count) docs")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(task.record.completedAt ?? HUDVisuals.relativeTime(task.mtime, l10n: l10n))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(InteractiveSurfaceButtonStyle(
            isSelected: isSelected,
            cornerRadius: 7,
            selectedFill: Color.accentColor.opacity(0.18)
        ))
    }

    private func journalRow(_ journal: WorkspaceJournal, l10n: L10n) -> some View {
        let isSelected = selection == .journal(journal.id)
        return Button {
            selection = .journal(journal.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                    Text("\(journal.developer) / \(journal.fileName)")
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if let heading = journal.latestHeading, !heading.isEmpty {
                    Text(heading)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack {
                    Text("\(journal.lineCount)L")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(HUDVisuals.relativeTime(journal.mtime, l10n: l10n))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(InteractiveSurfaceButtonStyle(
            isSelected: isSelected,
            cornerRadius: 7,
            selectedFill: Color.accentColor.opacity(0.18)
        ))
    }

    private func memoryRow(_ session: MemorySessionItem, l10n: L10n) -> some View {
        let isSelected = selection == .memory(session.id)
        return Button {
            selection = .memory(session.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    StatusPill(text: HUDVisuals.displayName(for: session.platform, l10n: l10n), color: .purple)
                    Text(session.title?.isEmpty == false ? session.title! : session.id)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if let snippet = session.excerpts.first?.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack {
                    if let cwd = session.cwd, !cwd.isEmpty {
                        Text(URL(fileURLWithPath: cwd).lastPathComponent)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if session.matchCount > 0 {
                        Text(l10n.t("\(session.matchCount) hits", "\(session.matchCount) 命中"))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text(HUDVisuals.relativeTime(session.updatedAt ?? session.createdAt, l10n: l10n))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(InteractiveSurfaceButtonStyle(
            isSelected: isSelected,
            cornerRadius: 7,
            selectedFill: Color.accentColor.opacity(0.18)
        ))
    }

    // MARK: - Right Preview Pane

    @ViewBuilder
    private func historyPreviewPane(l10n: L10n) -> some View {
        switch selection {
        case .archived(let id):
            if let task = filteredArchived.first(where: { $0.id == id }) {
                ArchivedTaskPreviewPane(store: store, task: task)
                    .id(task.id)
            } else {
                emptyPreview(l10n: l10n)
            }
        case .journal(let id):
            if let journal = filteredJournals.first(where: { $0.id == id }) {
                journalPreview(journal, l10n: l10n)
            } else {
                emptyPreview(l10n: l10n)
            }
        case .memory(let id):
            if let session = filteredMemory.first(where: { $0.id == id }) {
                memoryPreview(session, l10n: l10n)
            } else {
                emptyPreview(l10n: l10n)
            }
        case nil:
            emptyPreview(l10n: l10n)
        }
    }

    private func emptyPreview(l10n: L10n) -> some View {
        EmptyStatePlaceholder(
            systemImage: "doc.text.magnifyingglass",
            title: l10n.t("Select a History Entry", "选择一条历史记录"),
            subtitle: l10n.t(
                "Choose an archived task, developer journal, or cross-platform trellis mem session on the left.",
                "在左侧选择已归档任务、开发日志或跨平台 trellis mem 会话以查看完整内容。"
            )
        )
    }

    private func journalPreview(_ journal: WorkspaceJournal, l10n: L10n) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(journal.developer) · \(journal.fileName)")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(l10n.t(
                        "\(journal.lineCount) lines · Updated \(HUDVisuals.shortDate(journal.mtime))",
                        "\(journal.lineCount) 行 · 更新于 \(HUDVisuals.shortDate(journal.mtime))"
                    ))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.openInEditor(path: journal.filePath)
                } label: {
                    Label(l10n.t("Open", "打开"), systemImage: "square.and.pencil")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))

            Divider().opacity(0.5)

            ScrollView {
                MarkdownRendererView(
                    markdown: journal.content.isEmpty ? journal.preview : journal.content,
                    isChinese: l10n.isChinese
                )
                .equatable()
                .padding(14)
            }
        }
    }

    private func memoryPreview(_ session: MemorySessionItem, l10n: L10n) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title?.isEmpty == false ? session.title! : session.id)
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(session.id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !session.filePath.isEmpty {
                        Button {
                            store.openInEditor(path: session.filePath)
                        } label: {
                            Label(l10n.t("Open", "打开"), systemImage: "doc.text")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 6) {
                    StatusPill(text: HUDVisuals.displayName(for: session.platform, l10n: l10n), color: .purple)
                    if let cwd = session.cwd, !cwd.isEmpty {
                        StatusPill(text: HUDVisuals.abbreviateHome(cwd), color: .secondary, systemImage: "folder")
                    }
                    if let updated = session.updatedAt ?? session.createdAt {
                        StatusPill(text: HUDVisuals.shortDate(updated), color: .secondary)
                    }
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if session.excerpts.isEmpty {
                        Text(l10n.t(
                            "No excerpts returned for this session. Type a query above to search session content via trellis mem.",
                            "该会话暂无摘要片段。在上方输入关键词即可通过 trellis mem 检索会话内容。"
                        ))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(session.excerpts.enumerated()), id: \.offset) { _, excerpt in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(excerpt.role.uppercased())
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(excerpt.role.lowercased() == "user" ? Color.blue : Color.secondary)
                                MarkdownRendererView(markdown: excerpt.snippet, isChinese: l10n.isChinese)
                                    .equatable()
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.75)
                            )
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: - Helpers

    private func archiveMonth(for task: TaskSnapshot, l10n: L10n) -> String {
        let parts = task.dir.split(separator: "/")
        if parts.count >= 2, parts[0] == "archive" {
            return String(parts[1])
        }
        if let completed = task.record.completedAt, completed.count >= 7 {
            return String(completed.prefix(7))
        }
        return task.mtime == .distantPast ? l10n.t("Earlier", "更早") : HUDVisuals.yearMonth(task.mtime)
    }

    private func ensureValidSelection() {
        switch selection {
        case .archived(let id) where filteredArchived.contains(where: { $0.id == id }):
            return
        case .journal(let id) where filteredJournals.contains(where: { $0.id == id }):
            return
        case .memory(let id) where filteredMemory.contains(where: { $0.id == id }):
            return
        default:
            break
        }

        if (sourceFilter == .all || sourceFilter == .archived), let first = filteredArchived.first {
            selection = .archived(first.id)
        } else if (sourceFilter == .all || sourceFilter == .journals), let first = filteredJournals.first {
            selection = .journal(first.id)
        } else if (sourceFilter == .all || sourceFilter == .mem), let first = filteredMemory.first {
            selection = .memory(first.id)
        } else {
            selection = nil
        }
    }
}

// MARK: - Archived Task Multi-Document Preview Pane (User Issue #3)

private struct ArchivedTaskPreviewPane: View {
    let store: HUDStore
    let task: TaskSnapshot

    private enum DocChoice: Hashable {
        case overview
        case document(String)
    }

    @State private var selectedChoice: DocChoice
    @State private var loadedContent: String = ""
    @State private var isLoading: Bool = false

    init(store: HUDStore, task: TaskSnapshot) {
        self.store = store
        self.task = task
        // Default directly to PRD (or first doc) when available so full archived docs are 1 click away!
        let docs = orderedTaskDocs(for: task, l10n: store.l10n)
        if let first = docs.first {
            self._selectedChoice = State(initialValue: .document(first.path))
        } else {
            self._selectedChoice = State(initialValue: .overview)
        }
    }

    var body: some View {
        let l10n = store.l10n
        let docs = orderedTaskDocs(for: task, l10n: l10n)

        VStack(alignment: .leading, spacing: 0) {
            // Metadata header
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.record.title.isEmpty ? task.dir : task.record.title)
                            .font(.system(size: 14, weight: .semibold))
                        Text(task.dir)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    if case .document(let relPath) = selectedChoice {
                        Button {
                            store.openDocumentInEditor(for: task, relativePath: relPath)
                        } label: {
                            Label(l10n.t("Open in Editor", "用编辑器打开"), systemImage: "square.and.pencil")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button {
                        store.revealInFinder(path: task.taskDirectoryPath)
                    } label: {
                        Label(l10n.t("Reveal in Finder", "在访达中显示"), systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack(spacing: 6) {
                    StatusPill(text: l10n.t("Archived", "已归档"), color: .green, systemImage: "archivebox.fill")
                    StatusPill(text: task.record.priority, color: .secondary)
                    if let branch = task.record.branch, !branch.isEmpty {
                        StatusPill(text: branch, color: .blue, systemImage: "arrow.triangle.branch")
                    }
                    if let completed = task.record.completedAt, !completed.isEmpty {
                        StatusPill(text: completed, color: .secondary)
                    }
                    if task.totalChecklistCount > 0 {
                        StatusPill(
                            text: l10n.t("\(task.completedChecklistCount)/\(task.totalChecklistCount) checks", "\(task.completedChecklistCount)/\(task.totalChecklistCount) 项清单"),
                            color: .green
                        )
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))

            Divider().opacity(0.45)

            // Document switcher bar (Overview + PRD / Design / Implement / Research / etc.)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    docPill(
                        choice: .overview,
                        label: l10n.t("Overview", "概览"),
                        icon: "info.circle"
                    )
                    ForEach(docs) { doc in
                        docPill(
                            choice: .document(doc.path),
                            label: doc.label,
                            icon: doc.icon
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))

            Divider().opacity(0.45)

            // Content body
            switch selectedChoice {
            case .overview:
                overviewBody(l10n: l10n)
            case .document(let relPath):
                if isLoading {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(l10n.t("Loading \(relPath)…", "正在加载 \(relPath)…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        MarkdownRendererView(markdown: loadedContent, isChinese: l10n.isChinese)
                            .equatable()
                            .padding(14)
                    }
                }
            }
        }
        .task(id: selectedChoice) {
            guard case .document(let relPath) = selectedChoice else { return }
            isLoading = true
            let content = await store.loadDocument(for: task, relativePath: relPath)
            guard !Task.isCancelled else { return }
            loadedContent = content
            isLoading = false
        }
    }

    private func docPill(choice: DocChoice, label: String, icon: String) -> some View {
        let isSelected = selectedChoice == choice
        return Button {
            selectedChoice = choice
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 9.5)
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

    private func overviewBody(l10n: L10n) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !task.record.description.isEmpty {
                    MarkdownRendererView(markdown: task.record.description, isChinese: l10n.isChinese)
                        .equatable()
                }
                if !task.excerpt.isEmpty {
                    WorkbenchCard(title: l10n.t("Summary Excerpt", "摘要"), systemImage: "text.alignleft") {
                        MarkdownRendererView(markdown: task.excerpt, isChinese: l10n.isChinese)
                            .equatable()
                    }
                }
                if !task.checklist.isEmpty {
                    WorkbenchCard(
                        title: l10n.t(
                            "Checklist (\(task.completedChecklistCount)/\(task.totalChecklistCount))",
                            "清单 (\(task.completedChecklistCount)/\(task.totalChecklistCount))"
                        ),
                        systemImage: "checklist"
                    ) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(task.checklist.prefix(20)) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 11))
                                        .foregroundStyle(item.isCompleted ? .green : .secondary)
                                    InlineMarkdownText(item.text)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(item.isCompleted ? .secondary : .primary)
                                }
                            }
                        }
                    }
                }
                if !task.record.notes.isEmpty {
                    WorkbenchCard(title: l10n.t("Notes", "备注"), systemImage: "note.text") {
                        MarkdownRendererView(markdown: task.record.notes, isChinese: l10n.isChinese)
                            .equatable()
                    }
                }
                if task.record.description.isEmpty && task.excerpt.isEmpty && task.record.notes.isEmpty && task.checklist.isEmpty {
                    Text(l10n.t(
                        "No summary metadata stored for this archived task. Select a document pill above to read full Markdown files.",
                        "该归档任务暂无摘要信息，请点击上方文档标签查看完整 Markdown 文档。"
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }
}
