import SwiftUI
import TrellisCore

struct DocsSpecTabView: View {
    let store: HUDStore

    private enum SubMode: String, CaseIterable, Identifiable {
        case taskDocs = "Task Docs"
        case projectSpecs = "Project Specs"
        var id: String { rawValue }
    }

    @State private var mode: SubMode = .taskDocs
    @State private var specFilterQuery: String = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.45)

            switch mode {
            case .taskDocs:
                taskDocsView
            case .projectSpecs:
                projectSpecsView
            }
        }
    }

    // MARK: - Segmented Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mode) {
                Text("Task Docs (\(store.selectedTask?.artifacts.documentPaths.count ?? 0))")
                    .tag(SubMode.taskDocs)
                Text("Project Specs (\(store.specs.count))")
                    .tag(SubMode.projectSpecs)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 310)

            Spacer()

            if mode == .taskDocs {
                if let docPath = store.selectedDocPath {
                    Button {
                        store.reloadCurrentDocument()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        store.openDocumentInEditor(docPath)
                    } label: {
                        Label("Open in Editor", systemImage: "square.and.pencil")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                let filled = store.specs.filter { !$0.isEmptyTemplate }.count
                let empty = store.specs.count - filled
                HStack(spacing: 6) {
                    StatusPill(text: "\(filled) filled", color: .green)
                    if empty > 0 {
                        StatusPill(text: "\(empty) template", color: .orange)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Mode 1: Task Docs

    private var taskDocsView: some View {
        VStack(spacing: 0) {
            if let task = store.selectedTask {
                let orderedDocs = orderedTaskDocs(for: task)
                if orderedDocs.isEmpty {
                    EmptyStatePlaceholder(
                        systemImage: "doc.text",
                        title: "No Markdown Documents Yet",
                        subtitle: "Documents in .trellis/tasks/\(task.dir)/ (prd.md, design.md, implement.md, research) will appear here."
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(orderedDocs, id: \.path) { item in
                                let isSelected = store.selectedDocPath == item.path
                                Button {
                                    store.loadDocument(item.path)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: item.icon)
                                            .font(.system(size: 10))
                                        Text(item.label)
                                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                    }
                                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4.5)
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
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                    }

                    Divider().opacity(0.35)

                    if store.isLoadingDoc {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading document…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            MarkdownRendererView(markdown: store.selectedDocContent)
                                .padding(16)
                        }
                    }
                }
            } else {
                EmptyStatePlaceholder(
                    systemImage: "doc.plaintext",
                    title: "No Active Task Selected",
                    subtitle: "Pick an active task in the top bar to read its PRD, Design, Implementation Plan, and Research notes."
                )
                .frame(maxHeight: .infinity)
            }
        }
    }

    private struct TaskDocTabItem {
        let path: String
        let label: String
        let icon: String
    }

    private func orderedTaskDocs(for task: TaskSnapshot) -> [TaskDocTabItem] {
        let paths = task.artifacts.documentPaths
        var ordered: [TaskDocTabItem] = []
        var consumed = Set<String>()

        func appendIfPresent(_ target: String, label: String, icon: String) {
            if let match = paths.first(where: { $0.lowercased() == target.lowercased() }) {
                ordered.append(.init(path: match, label: label, icon: icon))
                consumed.insert(match)
            }
        }

        appendIfPresent("prd.md", label: "PRD", icon: "doc.text.fill")
        appendIfPresent("design.md", label: "Design", icon: "rectangle.3.group")
        appendIfPresent("implement.md", label: "Implement", icon: "hammer")

        // Research documents next
        let researchDocs = paths.filter {
            !consumed.contains($0) && $0.lowercased().contains("research")
        }.sorted()
        for doc in researchDocs {
            let shortName = URL(fileURLWithPath: doc).deletingPathExtension().lastPathComponent
            let label = researchDocs.count == 1 ? "Research" : "Research: \(shortName)"
            ordered.append(.init(path: doc, label: label, icon: "magnifyingglass.circle"))
            consumed.insert(doc)
        }

        // Remaining markdown docs
        for doc in paths where !consumed.contains(doc) {
            ordered.append(.init(path: doc, label: doc, icon: "doc.plaintext"))
        }

        return ordered
    }

    // MARK: - Mode 2: 3-Level Monorepo Project Specs Tree + Preview

    private var projectSpecsView: some View {
        Group {
            if store.specs.isEmpty {
                EmptyStatePlaceholder(
                    systemImage: "books.vertical",
                    title: "No Project Specs Found",
                    subtitle: "Add markdown guidelines under .trellis/spec/ to enable path-glob governance and live preview."
                )
                .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    specTreeSidebar
                        .frame(width: 245)

                    Divider().opacity(0.45)

                    specDetailPreview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var filteredSpecs: [SpecDocument] {
        let q = specFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.specs }
        return store.specs.filter { spec in
            spec.name.lowercased().contains(q)
                || spec.relativePath.lowercased().contains(q)
                || spec.category.lowercased().contains(q)
                || (spec.packageName?.lowercased().contains(q) ?? false)
                || (spec.layer?.lowercased().contains(q) ?? false)
                || spec.pathGlobs.contains(where: { $0.lowercased().contains(q) })
        }
    }

    private var specTreeSidebar: some View {
        let specs = filteredSpecs
        let byPackage = Dictionary(grouping: specs) { spec -> String in
            if let pkg = spec.packageName, !pkg.isEmpty { return pkg }
            return "Workspace"
        }
        let sortedPackages = byPackage.keys.sorted { lhs, rhs in
            if lhs == "Workspace" { return true }
            if rhs == "Workspace" { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                TextField("Filter specs or globs…", text: $specFilterQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                if !specFilterQuery.isEmpty {
                    Button {
                        specFilterQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))

            Divider().opacity(0.35)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(sortedPackages, id: \.self) { pkg in
                        let pkgSpecs = byPackage[pkg] ?? []
                        SpecPackageNode(
                            packageName: pkg,
                            specs: pkgSpecs,
                            selectedRelativePath: store.selectedSpec?.relativePath,
                            onSelect: { store.selectSpec($0) }
                        )
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private var specDetailPreview: some View {
        if let spec = store.selectedSpec {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spec.name)
                                .font(.system(size: 13.5, weight: .semibold))
                            Text(spec.relativePath)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button {
                            store.openSpecInEditor(spec)
                        } label: {
                            Label("Open", systemImage: "square.and.pencil")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    HStack(spacing: 6) {
                        StatusPill(
                            text: spec.isEmptyTemplate ? "Empty Template" : "Filled",
                            color: spec.isEmptyTemplate ? .orange : .green,
                            systemImage: spec.isEmptyTemplate ? "exclamationmark.circle" : "checkmark.circle.fill"
                        )
                        StatusPill(text: "\(spec.lineCount) lines", color: .secondary)
                        if spec.referencedByTaskCount > 0 {
                            StatusPill(text: "Ref ×\(spec.referencedByTaskCount)", color: .blue)
                        }
                        if !spec.matchedModifiedFiles.isEmpty {
                            StatusPill(
                                text: "\(spec.matchedModifiedFiles.count) dirty match",
                                color: .green,
                                systemImage: "checkmark.shield.fill"
                            )
                        }
                    }

                    if !spec.pathGlobs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                Text("paths:")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                ForEach(spec.pathGlobs, id: \.self) { glob in
                                    Text(glob)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.primary.opacity(0.85))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                    }

                    if !spec.matchedModifiedFiles.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                Text("matched:")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.green)
                                ForEach(spec.matchedModifiedFiles, id: \.self) { file in
                                    Text(file)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.025))

                Divider().opacity(0.4)

                ScrollView {
                    MarkdownRendererView(markdown: spec.content)
                        .padding(14)
                }
            }
        } else {
            EmptyStatePlaceholder(
                systemImage: "doc.text.magnifyingglass",
                title: "Select a Spec",
                subtitle: "Choose a specification from the tree on the left to inspect its globs, health, and guidelines."
            )
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - 3-Level Monorepo Spec Tree Nodes

private struct SpecPackageNode: View {
    let packageName: String
    let specs: [SpecDocument]
    let selectedRelativePath: String?
    let onSelect: (String) -> Void
    @State private var isExpanded = true

    var body: some View {
        let byLayer = Dictionary(grouping: specs) { spec -> String in
            if let layer = spec.layer, !layer.isEmpty { return layer }
            return spec.category.isEmpty ? "general" : spec.category
        }
        let sortedLayers = byLayer.keys.sorted()

        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sortedLayers, id: \.self) { layer in
                    SpecLayerNode(
                        layerName: layer,
                        specs: (byLayer[layer] ?? []).sorted { $0.name < $1.name },
                        selectedRelativePath: selectedRelativePath,
                        onSelect: onSelect
                    )
                }
            }
            .padding(.leading, 4)
            .padding(.top, 2)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: packageName == "Workspace" ? "folder.fill" : "shippingbox.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(packageName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(specs.count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct SpecLayerNode: View {
    let layerName: String
    let specs: [SpecDocument]
    let selectedRelativePath: String?
    let onSelect: (String) -> Void
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(specs) { spec in
                    let isSelected = spec.relativePath == selectedRelativePath
                    Button {
                        onSelect(spec.relativePath)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(spec.isEmptyTemplate ? Color.orange : Color.green)
                                .frame(width: 6, height: 6)

                            Text(spec.name)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer(minLength: 4)

                            if !spec.matchedModifiedFiles.isEmpty {
                                Text("\(spec.matchedModifiedFiles.count)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 4.5)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.16), in: Capsule())
                            }

                            Text("\(spec.lineCount)L")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4.5)
                        .background(
                            isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        } label: {
            HStack(spacing: 4) {
                Text(layerName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(specs.count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
