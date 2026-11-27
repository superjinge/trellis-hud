import SwiftUI
import TrellisCore

struct HistoryTabView: View {
    let store: HUDStore

    private enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case archived = "Archived Tasks"
        case journals = "Journals"
        case mem = "Mem Sessions"
        var id: String { rawValue }
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
        VStack(spacing: 0) {
            filterHeader
            Divider().opacity(0.45)

            HStack(spacing: 0) {
                historyListPane
                    .frame(width: 265)
                Divider().opacity(0.45)
                historyPreviewPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if searchText != store.historyQuery {
                searchText = store.historyQuery
            }
            ensureValidSelection()
        }
        .onChange(of: store.archivedTasks) { _, _ in ensureValidSelection() }
        .onChange(of: store.journals) { _, _ in ensureValidSelection() }
        .onChange(of: store.memorySessions) { _, _ in ensureValidSelection() }
    }

    // MARK: - Search + Source + Platform Filter Bar

    private var filterHeader: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("Search archived tasks, journals, and trellis mem…", text: $searchText)
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
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5.5)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if sourceFilter == .all || sourceFilter == .mem {
                    Menu {
                        Button {
                            platformFilter = nil
                        } label: {
                            HStack {
                                Text("All Platforms")
                                if platformFilter == nil { Image(systemName: "checkmark") }
                            }
                        }
                        Divider()
                        ForEach(MemoryPlatform.allCases.filter { $0 != .unknown }, id: \.self) { platform in
                            Button {
                                platformFilter = platform
                            } label: {
                                HStack {
                                    Text(HUDVisuals.displayName(for: platform))
                                    if platformFilter == platform { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 11))
                            Text(platformFilter.map { HUDVisuals.displayName(for: $0) } ?? "Platform")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(platformFilter == nil ? Color.secondary : Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            HStack(spacing: 5) {
                ForEach(SourceFilter.allCases) { filter in
                    let isSelected = sourceFilter == filter
                    Button {
                        sourceFilter = filter
                        ensureValidSelection()
                    } label: {
                        HStack(spacing: 4) {
                            Text(filter.rawValue)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            Text("\(countFor(filter))")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8.5)
                        .padding(.vertical, 3.5)
                        .background(
                            isSelected ? Color.primary.opacity(0.11) : Color.clear,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
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

    private var historyListPane: some View {
        let showArchived = sourceFilter == .all || sourceFilter == .archived
        let showJournals = sourceFilter == .all || sourceFilter == .journals
        let showMem = sourceFilter == .all || sourceFilter == .mem

        let hasAny = (showArchived && !filteredArchived.isEmpty)
            || (showJournals && !filteredJournals.isEmpty)
            || (showMem && !filteredMemory.isEmpty)

        return Group {
            if !hasAny {
                EmptyStatePlaceholder(
                    systemImage: "clock.arrow.circlepath",
                    title: "No Matching History",
                    subtitle: "Try a broader search term or switch source / platform filters."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if showArchived && !filteredArchived.isEmpty {
                            let grouped = Dictionary(grouping: filteredArchived, by: archiveMonth(for:))
                            let months = grouped.keys.sorted(by: >)
                            ForEach(months, id: \.self) { month in
                                sectionHeader("Archived · \(month)", count: grouped[month]?.count ?? 0)
                                ForEach(grouped[month] ?? []) { task in
                                    archivedRow(task)
                                }
                            }
                        }

                        if showJournals && !filteredJournals.isEmpty {
                            sectionHeader("Workspace Journals", count: filteredJournals.count)
                            ForEach(filteredJournals) { journal in
                                journalRow(journal)
                            }
                        }

                        if showMem && !filteredMemory.isEmpty {
                            sectionHeader("Trellis Mem Sessions", count: filteredMemory.count)
                            ForEach(filteredMemory) { session in
                                memoryRow(session)
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
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
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private func archivedRow(_ task: TaskSnapshot) -> some View {
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
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Text(task.record.completedAt ?? HUDVisuals.relativeTime(task.mtime))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func journalRow(_ journal: WorkspaceJournal) -> some View {
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
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(HUDVisuals.relativeTime(journal.mtime))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func memoryRow(_ session: MemorySessionItem) -> some View {
        let isSelected = selection == .memory(session.id)
        return Button {
            selection = .memory(session.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    StatusPill(text: HUDVisuals.displayName(for: session.platform), color: .purple)
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
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if session.matchCount > 0 {
                        Text("\(session.matchCount) hits")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text(HUDVisuals.relativeTime(session.updatedAt ?? session.createdAt))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right Preview Pane

    @ViewBuilder
    private var historyPreviewPane: some View {
        switch selection {
        case .archived(let id):
            if let task = filteredArchived.first(where: { $0.id == id }) {
                archivedPreview(task)
            } else {
                emptyPreview
            }
        case .journal(let id):
            if let journal = filteredJournals.first(where: { $0.id == id }) {
                journalPreview(journal)
            } else {
                emptyPreview
            }
        case .memory(let id):
            if let session = filteredMemory.first(where: { $0.id == id }) {
                memoryPreview(session)
            } else {
                emptyPreview
            }
        case nil:
            emptyPreview
        }
    }

    private var emptyPreview: some View {
        EmptyStatePlaceholder(
            systemImage: "doc.text.magnifyingglass",
            title: "Select a History Entry",
            subtitle: "Choose an archived task, developer journal, or cross-platform trellis mem session on the left."
        )
    }

    private func archivedPreview(_ task: TaskSnapshot) -> some View {
        let taskDirPath = URL(fileURLWithPath: task.projectPath)
            .appendingPathComponent(".trellis/tasks", isDirectory: true)
            .appendingPathComponent(task.dir, isDirectory: true)
            .path

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.record.title.isEmpty ? task.dir : task.record.title)
                            .font(.system(size: 14, weight: .semibold))
                        Text(task.dir)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        store.openInEditor(path: taskDirPath)
                    } label: {
                        Label("Reveal", systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack(spacing: 6) {
                    StatusPill(text: "Archived", color: .green, systemImage: "archivebox.fill")
                    StatusPill(text: task.record.priority, color: .secondary)
                    if let branch = task.record.branch, !branch.isEmpty {
                        StatusPill(text: branch, color: .blue, systemImage: "arrow.triangle.branch")
                    }
                    if let completed = task.record.completedAt, !completed.isEmpty {
                        StatusPill(text: completed, color: .secondary)
                    }
                    if task.totalChecklistCount > 0 {
                        StatusPill(
                            text: "\(task.completedChecklistCount)/\(task.totalChecklistCount) checks",
                            color: .green
                        )
                    }
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.025))

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !task.record.description.isEmpty {
                        MarkdownRendererView(markdown: task.record.description)
                    }
                    if !task.excerpt.isEmpty {
                        MarkdownRendererView(markdown: task.excerpt)
                    }
                    if !task.record.notes.isEmpty {
                        WorkbenchCard(title: "Notes", systemImage: "note.text") {
                            MarkdownRendererView(markdown: task.record.notes)
                        }
                    }
                    if task.record.description.isEmpty && task.excerpt.isEmpty && task.record.notes.isEmpty {
                        Text("No summary excerpt stored for this archived task.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
        }
    }

    private func journalPreview(_ journal: WorkspaceJournal) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(journal.developer) · \(journal.fileName)")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("\(journal.lineCount) lines · Updated \(HUDVisuals.shortDate(journal.mtime))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.openInEditor(path: journal.filePath)
                } label: {
                    Label("Open", systemImage: "square.and.pencil")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(14)
            .background(Color.primary.opacity(0.025))

            Divider().opacity(0.4)

            ScrollView {
                MarkdownRendererView(markdown: journal.content.isEmpty ? journal.preview : journal.content)
                    .padding(14)
            }
        }
    }

    private func memoryPreview(_ session: MemorySessionItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title?.isEmpty == false ? session.title! : session.id)
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(session.id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if !session.filePath.isEmpty {
                        Button {
                            store.openInEditor(path: session.filePath)
                        } label: {
                            Label("Open", systemImage: "doc.text")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 6) {
                    StatusPill(text: HUDVisuals.displayName(for: session.platform), color: .purple)
                    if let cwd = session.cwd, !cwd.isEmpty {
                        StatusPill(text: HUDVisuals.abbreviateHome(cwd), color: .secondary, systemImage: "folder")
                    }
                    if let updated = session.updatedAt ?? session.createdAt {
                        StatusPill(text: HUDVisuals.shortDate(updated), color: .secondary)
                    }
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.025))

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if session.excerpts.isEmpty {
                        Text("No excerpts returned for this session. Type a query above to search session content via trellis mem.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(session.excerpts.enumerated()), id: \.offset) { _, excerpt in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(excerpt.role.uppercased())
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(excerpt.role.lowercased() == "user" ? Color.blue : Color.secondary)
                                MarkdownRendererView(markdown: excerpt.snippet)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: - Helpers

    private func archiveMonth(for task: TaskSnapshot) -> String {
        let parts = task.dir.split(separator: "/")
        if parts.count >= 2, parts[0] == "archive" {
            return String(parts[1])
        }
        if let completed = task.record.completedAt, completed.count >= 7 {
            return String(completed.prefix(7))
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return task.mtime == .distantPast ? "Earlier" : formatter.string(from: task.mtime)
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
