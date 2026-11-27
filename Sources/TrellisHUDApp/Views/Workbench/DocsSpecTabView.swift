import SwiftUI
import TrellisCore

struct DocsSpecTabView: View {
    @Bindable var store: HUDStore

    @State private var specFilterQuery: String = ""

    var body: some View {
        let l10n = store.l10n

        VStack(spacing: 0) {
            headerBar(l10n: l10n)
            Divider().opacity(0.55)

            switch store.docsSubMode {
            case .taskDocs:
                taskDocsView(l10n: l10n)
            case .projectSpecs:
                projectSpecsView(l10n: l10n)
            }
        }
    }

    // MARK: - Segmented Header

    private func headerBar(l10n: L10n) -> some View {
        HStack(spacing: 10) {
            Picker("", selection: $store.docsSubMode) {
                Text(l10n.t(
                    "Task Docs (\(store.selectedTask?.artifacts.documentPaths.count ?? 0))",
                    "任务文档 (\(store.selectedTask?.artifacts.documentPaths.count ?? 0))"
                ))
                .tag(DocsSubMode.taskDocs)
                Text(l10n.t(
                    "Project Specs (\(store.specs.count))",
                    "项目规范 (\(store.specs.count))"
                ))
                .tag(DocsSubMode.projectSpecs)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            Spacer()

            if store.docsSubMode == .taskDocs {
                if let docPath = store.selectedDocPath {
                    Button {
                        store.reloadCurrentDocument()
                    } label: {
                        Label(l10n.t("Reload", "刷新"), systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        store.openDocumentInEditor(docPath)
                    } label: {
                        Label(l10n.t("Open in Editor", "用编辑器打开"), systemImage: "square.and.pencil")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                let filled = store.specs.filter { !$0.isEmptyTemplate }.count
                let empty = store.specs.count - filled
                HStack(spacing: 6) {
                    StatusPill(text: l10n.t("\(filled) filled", "\(filled) 已填写"), color: .green)
                    if empty > 0 {
                        StatusPill(text: l10n.t("\(empty) template", "\(empty) 空模板"), color: .orange)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Mode 1: Task Docs

    private func taskDocsView(l10n: L10n) -> some View {
        VStack(spacing: 0) {
            if let task = store.selectedTask {
                let orderedDocs = orderedTaskDocs(for: task, l10n: l10n)
                if orderedDocs.isEmpty {
                    EmptyStatePlaceholder(
                        systemImage: "doc.text",
                        title: l10n.t("No Markdown Documents Yet", "暂无 Markdown 文档"),
                        subtitle: l10n.t(
                            "Documents in .trellis/tasks/\(task.dir)/ (prd.md, design.md, implement.md, research) will appear here.",
                            ".trellis/tasks/\(task.dir)/ 下的 prd.md、design.md、implement.md、research 文档将显示在此。"
                        )
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(orderedDocs) { item in
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
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                }
                                .buttonStyle(InteractiveSurfaceButtonStyle(
                                    isSelected: isSelected,
                                    isCapsule: true,
                                    baseFill: Color.primary.opacity(0.06),
                                    selectedFill: Color.accentColor.opacity(0.18),
                                    selectedBorder: Color.accentColor.opacity(0.45)
                                ))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                    }
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

                    Divider().opacity(0.45)

                    if store.isLoadingDoc {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(l10n.t("Loading document…", "正在加载文档…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            MarkdownRendererView(markdown: store.selectedDocContent, isChinese: l10n.isChinese)
                                .equatable()
                                .padding(16)
                        }
                    }
                }
            } else {
                EmptyStatePlaceholder(
                    systemImage: "doc.plaintext",
                    title: l10n.t("No Active Task Selected", "未选择进行中任务"),
                    subtitle: l10n.t(
                        "Pick an active task in the top bar to read its PRD, Design, Implementation Plan, and Research notes.",
                        "在顶栏选择一个进行中任务以阅读其 PRD、设计文档、实施计划和调研笔记。"
                    )
                )
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - Mode 2: 3-Level Monorepo Project Specs Tree + Preview

    private func projectSpecsView(l10n: L10n) -> some View {
        Group {
            if store.specs.isEmpty {
                EmptyStatePlaceholder(
                    systemImage: "books.vertical",
                    title: l10n.t("No Project Specs Found", "未找到项目规范"),
                    subtitle: l10n.t(
                        "Add markdown guidelines under .trellis/spec/ to enable path-glob governance and live preview.",
                        "在 .trellis/spec/ 下添加 Markdown 规范以启用路径匹配治理与实时预览。"
                    )
                )
                .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    specTreeSidebar(l10n: l10n)
                        .frame(width: 245)

                    Divider().opacity(0.55)

                    specDetailPreview(l10n: l10n)
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

    private func specTreeSidebar(l10n: L10n) -> some View {
        let specs = filteredSpecs
        let rootLabel = l10n.t("Workspace", "工作区")
        let byPackage = Dictionary(grouping: specs) { spec -> String in
            if let pkg = spec.packageName, !pkg.isEmpty { return pkg }
            return rootLabel
        }
        let sortedPackages = byPackage.keys.sorted { lhs, rhs in
            if lhs == rootLabel { return true }
            if rhs == rootLabel { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                TextField(l10n.t("Filter specs or globs…", "筛选规范或 paths glob…"), text: $specFilterQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                if !specFilterQuery.isEmpty {
                    Button {
                        specFilterQuery = ""
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
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))

            Divider().opacity(0.45)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(sortedPackages, id: \.self) { pkg in
                        let pkgSpecs = byPackage[pkg] ?? []
                        SpecPackageNode(
                            packageName: pkg,
                            isWorkspaceRoot: pkg == rootLabel,
                            specs: pkgSpecs,
                            selectedRelativePath: store.selectedSpec?.relativePath,
                            onSelect: { store.selectSpec($0) }
                        )
                    }
                }
                .padding(8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    @ViewBuilder
    private func specDetailPreview(l10n: L10n) -> some View {
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
                            Label(l10n.t("Open", "打开"), systemImage: "square.and.pencil")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    HStack(spacing: 6) {
                        StatusPill(
                            text: spec.isEmptyTemplate
                                ? l10n.t("Empty Template", "空模板")
                                : l10n.t("Filled", "已填写"),
                            color: spec.isEmptyTemplate ? .orange : .green,
                            systemImage: spec.isEmptyTemplate ? "exclamationmark.circle" : "checkmark.circle.fill"
                        )
                        StatusPill(text: l10n.t("\(spec.lineCount) lines", "\(spec.lineCount) 行"), color: .secondary)
                        if spec.referencedByTaskCount > 0 {
                            StatusPill(text: l10n.t("Ref ×\(spec.referencedByTaskCount)", "引用 ×\(spec.referencedByTaskCount)"), color: .blue)
                        }
                        if !spec.matchedModifiedFiles.isEmpty {
                            StatusPill(
                                text: l10n.t("\(spec.matchedModifiedFiles.count) dirty match", "命中 \(spec.matchedModifiedFiles.count) 个改动"),
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
                                        .foregroundStyle(.primary.opacity(0.9))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                    }

                    if !spec.matchedModifiedFiles.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                Text(l10n.t("matched:", "命中:"))
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.green)
                                ForEach(spec.matchedModifiedFiles, id: \.self) { file in
                                    Text(file)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))

                Divider().opacity(0.5)

                ScrollView {
                    MarkdownRendererView(markdown: spec.content, isChinese: l10n.isChinese)
                        .equatable()
                        .padding(14)
                }
            }
        } else {
            EmptyStatePlaceholder(
                systemImage: "doc.text.magnifyingglass",
                title: l10n.t("Select a Spec", "选择规范文档"),
                subtitle: l10n.t(
                    "Choose a specification from the tree on the left to inspect its globs, health, and guidelines.",
                    "从左侧目录树中选择一份规范以查看路径匹配规则、完整度与详细内容。"
                )
            )
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - 3-Level Monorepo Spec Tree Nodes

private struct SpecPackageNode: View {
    let packageName: String
    let isWorkspaceRoot: Bool
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
                Image(systemName: isWorkspaceRoot ? "folder.fill" : "shippingbox.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(packageName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(specs.count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
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
                                    .background(Color.green.opacity(0.18), in: Capsule())
                            }

                            Text("\(spec.lineCount)L")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(InteractiveSurfaceButtonStyle(
                        isSelected: isSelected,
                        cornerRadius: 6,
                        selectedFill: Color.accentColor.opacity(0.18)
                    ))
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
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
    }
}
