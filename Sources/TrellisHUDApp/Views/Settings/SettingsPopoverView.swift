import SwiftUI
import TrellisCore

public struct SettingsPopoverView: View {
    let store: HUDStore

    public init(store: HUDStore) {
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                displayModeSection
                Divider().opacity(0.5)
                watchedProjectsSection
                Divider().opacity(0.5)
                agentHooksSection
                Divider().opacity(0.5)
                shortcutsSection
            }
            .padding(14)
        }
        .frame(width: 390)
        .frame(maxHeight: 540)
        .onAppear {
            store.refreshHookStatuses()
        }
    }

    private var header: some View {
        HStack {
            Label("Trellis HUD Settings", systemImage: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                store.isSettingsOpen = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Display Mode

    private var displayModeSection: some View {
        let modeBinding = Binding<TrellisCore.PresentationMode>(
            get: { store.presentationMode },
            set: { store.setPresentationMode($0) }
        )
        let anchorBinding = Binding<EdgeAnchor>(
            get: { store.edgeAnchor },
            set: { store.setEdgeAnchor($0) }
        )
        let menuBarBinding = Binding<Bool>(
            get: { store.showMenuBarIcon },
            set: { store.setShowMenuBarIcon($0) }
        )
        let autoFollowBinding = Binding<Bool>(
            get: { store.autoFollowFocus },
            set: { store.setAutoFollowFocus($0) }
        )

        return VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Display Mode")

            Picker("HUD Mode", selection: modeBinding) {
                Text("Notch HUD").tag(TrellisCore.PresentationMode.notch)
                Text("Edge Pill").tag(TrellisCore.PresentationMode.edgePill)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Text("Edge Anchor")
                    .font(.system(size: 11.5))
                    .foregroundStyle(store.presentationMode == .edgePill ? .primary : .secondary)
                Spacer()
                Picker("", selection: anchorBinding) {
                    Text("Left").tag(EdgeAnchor.left)
                    Text("Right").tag(EdgeAnchor.right)
                    Text("Bottom Left").tag(EdgeAnchor.bottomLeft)
                    Text("Bottom Right").tag(EdgeAnchor.bottomRight)
                }
                .labelsHidden()
                .frame(width: 140)
                .disabled(store.presentationMode != .edgePill)
            }

            Toggle("Show Menu Bar Icon", isOn: menuBarBinding)
                .font(.system(size: 11.5))
                .toggleStyle(.switch)
                .controlSize(.small)

            Toggle("Auto-Follow Active Agent Focus", isOn: autoFollowBinding)
                .font(.system(size: 11.5))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: - Watched Projects

    private var watchedProjectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Watched Projects")
                Spacer()
                Button {
                    store.rediscoverProjects()
                } label: {
                    Label("Re-discover", systemImage: "arrow.clockwise")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.borderless)

                Button {
                    store.addRootFolderInteractive()
                } label: {
                    Label("Add Folder", systemImage: "plus")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if store.watchedRoots.isEmpty {
                Text("No root folders configured. Add a workspace folder to discover .trellis projects.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.watchedRoots, id: \.self) { root in
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Text(HUDVisuals.abbreviateHome(root))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                store.removeRootFolder(root)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove watched folder")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            if !store.projects.isEmpty {
                Text("\(store.projects.count) Trellis \(store.projects.count == 1 ? "project" : "projects") discovered")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Agent Hooks

    private var agentHooksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Agent Hooks")
                Spacer()
                Button {
                    store.refreshHookStatuses()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh hook install status")
            }

            VStack(spacing: 5) {
                ForEach(store.hookStatuses) { status in
                    hookRow(status)
                }
            }
        }
    }

    private func hookRow(_ status: AgentHookStatusInfo) -> some View {
        let isUpdating = store.updatingHookAgent == status.agent

        return HStack(spacing: 8) {
            Image(systemName: HUDVisuals.icon(for: status.agent))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 5) {
                    Text(status.agent.displayName)
                        .font(.system(size: 11.5, weight: .medium))
                    StatusPill(
                        text: status.installed ? "Installed" : (status.isSupported ? "Not Installed" : "Auto"),
                        color: status.installed ? .green : (status.isSupported ? .secondary : .blue)
                    )
                }

                Text(status.detail ?? HUDVisuals.abbreviateHome(status.configPath))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if status.isSupported {
                Button {
                    store.setHookEnabled(!status.installed, for: status.agent)
                } label: {
                    if isUpdating {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 48)
                    } else {
                        Text(status.installed ? "Remove" : "Install")
                            .font(.system(size: 10.5, weight: .medium))
                            .frame(minWidth: 48)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(status.installed ? .red : .accentColor)
                .disabled(store.updatingHookAgent != nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - Keyboard Shortcuts

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Shortcuts")

            shortcutRow(label: "Toggle Workbench", keys: "⌘⇧T")
            shortcutRow(label: "Switch Notch / Edge Pill", keys: "⌘⇧M")
            shortcutRow(label: "Collapse Workbench", keys: "Esc")
        }
    }

    private func shortcutRow(label: String, keys: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text(keys)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
