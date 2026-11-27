import SwiftUI
import TrellisCore

public struct WorkbenchContainerView: View {
    @Bindable var store: HUDStore

    public init(store: HUDStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.5)
            tabBar
            Divider().opacity(0.45)

            ZStack(alignment: .bottom) {
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let toast = store.statusToast {
                    toastBanner(toast)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: store.statusToast)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 22, x: 0, y: 10)
        .onExitCommand {
            store.collapse()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            projectSelector
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            taskSelector

            Spacer(minLength: 8)

            modeToggleButton
            refreshButton
            settingsButton
            collapseButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var projectSelector: some View {
        Menu {
            if store.projects.isEmpty {
                Text("No .trellis projects discovered")
                Divider()
                Button("Add Watched Folder…") {
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
                Button("Add Watched Folder…") {
                    store.addRootFolderInteractive()
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(HUDVisuals.color(for: store.globalStatus))
                    .frame(width: 7, height: 7)
                Text(store.selectedProject?.name ?? "No Project")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(store.selectedProject.map { HUDVisuals.abbreviateHome($0.path) } ?? "Select a Trellis project")
    }

    private var taskSelector: some View {
        Menu {
            if store.activeTasks.isEmpty {
                Text("No active tasks")
            } else {
                ForEach(store.activeTasks) { task in
                    Button {
                        store.selectTask(task.id)
                    } label: {
                        let label = task.record.title.isEmpty ? task.dir : task.record.title
                        HStack {
                            Text("\(label) · \(task.phase.label)")
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
                    Text("No Active Task")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var modeToggleButton: some View {
        Button {
            store.togglePresentationMode()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.presentationMode == .notch ? "rectangle.topthird.inset.filled" : "capsule.portrait.righthalf.filled")
                    .font(.system(size: 11))
                Text(store.presentationMode == .notch ? "Notch" : "Pill")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Switch Notch ↔ Edge Pill (⌘⇧M)")
    }

    private var refreshButton: some View {
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
            .frame(width: 24, height: 24)
            .foregroundStyle(.secondary)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(store.isRefreshing)
        .help("Refresh workspace & channels")
    }

    private var settingsButton: some View {
        Button {
            store.toggleSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(store.isSettingsOpen ? Color.accentColor : Color.secondary)
                .background(
                    (store.isSettingsOpen ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help("HUD Settings")
        .popover(isPresented: $store.isSettingsOpen, arrowEdge: .top) {
            SettingsPopoverView(store: store)
        }
    }

    private var collapseButton: some View {
        Button {
            store.collapse()
        } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .help("Collapse Workbench (Esc)")
    }

    // MARK: - 4-Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(WorkbenchTab.allCases) { tab in
                let isSelected = store.selectedTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        store.selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        Text(tab.title)
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(
                        isSelected ? Color.primary.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Active Tab Content

    @ViewBuilder
    private var tabContent: some View {
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

    // MARK: - Toast Overlay

    private func toastBanner(_ toast: StatusToast) -> some View {
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
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder((toast.isError ? Color.red : Color.primary).opacity(0.22), lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
    }
}
