import SwiftUI
import TrellisCore

public struct WorkbenchContainerView: View {
    let store: HUDStore

    public init(store: HUDStore) {
        self.store = store
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        VStack(spacing: 0) {
            WorkbenchTopBarView(store: store)
            Divider().opacity(0.6)
            WorkbenchTabBarView(store: store)
            Divider().opacity(0.55)

            ZStack(alignment: .bottom) {
                WorkbenchTabContentView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                WorkbenchToastOverlay(store: store)
            }
        }
        .background {
            ZStack {
                shape.fill(.thickMaterial)
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.88))
            }
        }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.75)
        )
        .overlay(alignment: .bottomTrailing) {
            ResizeGripAffordance()
        }
        .shadow(color: Color.black.opacity(0.24), radius: 22, x: 0, y: 10)
        .onExitCommand {
            store.collapse()
        }
    }
}

// MARK: - Isolated Top Bar (Prevents Toast / Tab Content Over-Invalidation)

private struct WorkbenchTopBarView: View {
    @Bindable var store: HUDStore

    var body: some View {
        let l10n = store.l10n

        HStack(spacing: 8) {
            projectSelector(l10n: l10n)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            taskSelector(l10n: l10n)

            Spacer(minLength: 8)

            modeToggleButton(l10n: l10n)
            refreshButton(l10n: l10n)
            settingsButton(l10n: l10n)
            collapseButton(l10n: l10n)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func projectSelector(l10n: L10n) -> some View {
        Menu {
            if store.projects.isEmpty {
                Text(l10n.t("No .trellis projects discovered", "未发现 .trellis 项目"))
                Divider()
                Button(l10n.t("Add Watched Folder…", "添加监听目录…")) {
                    store.addRootFolderInteractive()
                }
            } else {
                ForEach(store.projects) { project in
                    Button {
                        store.selectProject(project.path)
                    } label: {
                        HStack {
                            Text(project.name)
                            if project.activeTaskCount > 0 {
                                Text("(\(project.activeTaskCount))")
                            }
                            if project.path == store.selectedProject?.path {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button(l10n.t("Add Watched Folder…", "添加监听目录…")) {
                    store.addRootFolderInteractive()
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(HUDVisuals.color(for: store.globalStatus))
                    .frame(width: 7, height: 7)
                Text(store.selectedProject?.name ?? l10n.t("No Project", "未选项目"))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(store.selectedProject.map { HUDVisuals.abbreviateHome($0.path) } ?? l10n.t("Select a Trellis project", "选择 Trellis 项目"))
    }

    private func taskSelector(l10n: L10n) -> some View {
        Menu {
            if store.activeTasks.isEmpty {
                Text(l10n.t("No active tasks", "暂无进行中任务"))
            } else {
                ForEach(store.activeTasks) { task in
                    Button {
                        store.selectTask(task.id)
                    } label: {
                        let label = task.record.title.isEmpty ? task.dir : task.record.title
                        HStack {
                            Text("\(label) · \(l10n.phaseLabel(task.phase))")
                            if task.id == store.selectedTask?.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let task = store.selectedTask {
                    Text(task.record.title.isEmpty ? task.dir : task.record.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 230, alignment: .leading)
                } else {
                    Text(l10n.t("No Active Task", "无进行中任务"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func modeToggleButton(l10n: L10n) -> some View {
        Button {
            store.togglePresentationMode()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.presentationMode == .notch ? "rectangle.topthird.inset.filled" : "capsule.portrait.righthalf.filled")
                    .font(.system(size: 11))
                Text(l10n.modeLabel(store.presentationMode))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
        }
        .buttonStyle(InteractiveSurfaceButtonStyle(cornerRadius: 6, baseFill: Color.primary.opacity(0.07)))
        .help(l10n.t("Switch Notch ↔ Edge Pill (⌘⌥M)", "切换刘海 ↔ 吸边胶囊 (⌘⌥M)"))
    }

    private func refreshButton(l10n: L10n) -> some View {
        Button {
            store.refreshAll()
        } label: {
            Group {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .frame(width: 26, height: 26)
            .foregroundStyle(.primary.opacity(0.8))
        }
        .buttonStyle(InteractiveSurfaceButtonStyle(cornerRadius: 6, baseFill: Color.primary.opacity(0.06)))
        .disabled(store.isRefreshing)
        .help(l10n.t("Refresh workspace & channels", "刷新工作区与频道"))
    }

    private func settingsButton(l10n: L10n) -> some View {
        Button {
            store.toggleSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(store.isSettingsOpen ? Color.accentColor : Color.primary.opacity(0.8))
        }
        .buttonStyle(InteractiveSurfaceButtonStyle(
            isSelected: store.isSettingsOpen,
            cornerRadius: 6,
            baseFill: Color.primary.opacity(0.06),
            selectedFill: Color.accentColor.opacity(0.18)
        ))
        .help(l10n.t("HUD Settings", "HUD 设置"))
        .popover(isPresented: $store.isSettingsOpen, arrowEdge: .top) {
            SettingsPopoverView(store: store)
        }
    }

    private func collapseButton(l10n: L10n) -> some View {
        Button {
            store.collapse()
        } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(.primary.opacity(0.8))
        }
        .buttonStyle(InteractiveSurfaceButtonStyle(cornerRadius: 6, baseFill: Color.primary.opacity(0.06)))
        .keyboardShortcut(.escape, modifiers: [])
        .help(l10n.t("Collapse Workbench (Esc)", "收起工作台 (Esc)"))
    }
}

// MARK: - Isolated 4-Tab Bar (Instant Switch, Full Hit Area)

private struct WorkbenchTabBarView: View {
    let store: HUDStore

    var body: some View {
        let l10n = store.l10n

        HStack(spacing: 4) {
            ForEach(WorkbenchTab.allCases) { tab in
                let isSelected = store.selectedTab == tab
                Button {
                    store.selectedTab = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        Text(l10n.tabTitle(tab))
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))

                        if tab == .live && store.attentionCount > 0 {
                            Text("\(store.attentionCount)")
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange, in: Capsule())
                        }
                    }
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                }
                .buttonStyle(InteractiveSurfaceButtonStyle(
                    isSelected: isSelected,
                    cornerRadius: 7,
                    selectedFill: Color.primary.opacity(0.13)
                ))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Active Tab Content

private struct WorkbenchTabContentView: View {
    let store: HUDStore

    var body: some View {
        switch store.selectedTab {
        case .flow:
            FlowTabView(store: store)
        case .live:
            LiveChannelTabView(store: store)
        case .docsSpecs:
            DocsSpecTabView(store: store)
        case .history:
            HistoryTabView(store: store)
        }
    }
}

// MARK: - Isolated Toast Overlay

private struct WorkbenchToastOverlay: View {
    let store: HUDStore

    var body: some View {
        Group {
            if let toast = store.statusToast {
                HStack(spacing: 8) {
                    Image(systemName: toast.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(toast.isError ? Color.red : Color.green)
                    Text(toast.message)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button {
                        store.dismissToast()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(InteractiveSurfaceButtonStyle(cornerRadius: 4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Color(nsColor: .windowBackgroundColor).opacity(0.96),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder((toast.isError ? Color.red : Color(nsColor: .separatorColor)).opacity(0.55), lineWidth: 0.75)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.statusToast)
    }
}
