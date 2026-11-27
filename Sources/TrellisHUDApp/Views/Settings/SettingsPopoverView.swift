import SwiftUI
import TrellisCore

public struct SettingsPopoverView: View {
    let store: HUDStore

    public init(store: HUDStore) {
        self.store = store
    }

    public var body: some View {
        let l10n = store.l10n

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(l10n: l10n)
                displayModeSection(l10n: l10n)
                Divider().opacity(0.55)
                watchedProjectsSection(l10n: l10n)
                Divider().opacity(0.55)
                agentHooksSection(l10n: l10n)
                Divider().opacity(0.55)
                shortcutsSection(l10n: l10n)
            }
            .padding(14)
        }
        .frame(width: 400)
        .frame(maxHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            store.refreshHookStatuses()
        }
    }

    private func header(l10n: L10n) -> some View {
        HStack {
            Label(l10n.t("Trellis HUD Settings", "Trellis HUD 设置"), systemImage: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                store.isSettingsOpen = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(InteractiveSurfaceButtonStyle(cornerRadius: 6))
        }
    }

    // MARK: - Display Mode & Language

    private func displayModeSection(l10n: L10n) -> some View {
        let modeBinding = Binding<TrellisCore.PresentationMode>(
            get: { store.presentationMode },
            set: { store.setPresentationMode($0) }
        )
        let anchorBinding = Binding<EdgeAnchor>(
            get: { store.edgeAnchor },
            set: { store.setEdgeAnchor($0) }
        )
        let languageBinding = Binding<AppLanguage>(
            get: { store.language },
            set: { store.setLanguage($0) }
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
            sectionTitle(l10n.t("Display & Language", "显示与语言"))

            Picker(l10n.t("HUD Mode", "显示模式"), selection: modeBinding) {
                Text(l10n.modeFullLabel(.notch)).tag(TrellisCore.PresentationMode.notch)
                Text(l10n.modeFullLabel(.edgePill)).tag(TrellisCore.PresentationMode.edgePill)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Text(l10n.t("Edge Anchor", "吸边位置"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(store.presentationMode == .edgePill ? .primary : .secondary)
                Spacer()
                Picker("", selection: anchorBinding) {
                    Text(l10n.edgeAnchorLabel(.left)).tag(EdgeAnchor.left)
                    Text(l10n.edgeAnchorLabel(.right)).tag(EdgeAnchor.right)
                    Text(l10n.edgeAnchorLabel(.bottomLeft)).tag(EdgeAnchor.bottomLeft)
                    Text(l10n.edgeAnchorLabel(.bottomRight)).tag(EdgeAnchor.bottomRight)
                }
                .labelsHidden()
                .frame(width: 145)
                .disabled(store.presentationMode != .edgePill)
            }

            HStack {
                Text(l10n.t("Language", "界面语言"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                Spacer()
                Picker("", selection: languageBinding) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(l10n.languageOptionLabel(lang)).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 215)
            }

            Toggle(l10n.t("Show Menu Bar Icon", "显示菜单栏图标"), isOn: menuBarBinding)
                .font(.system(size: 11.5))
                .toggleStyle(.switch)
                .controlSize(.small)

            Toggle(l10n.t("Auto-Follow Active Agent Focus", "自动跟随活跃 Agent 焦点"), isOn: autoFollowBinding)
                .font(.system(size: 11.5))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: - Watched Projects

    private func watchedProjectsSection(l10n: L10n) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle(l10n.t("Watched Projects", "监听项目目录"))
                Spacer()
                Button {
                    store.rediscoverProjects()
                } label: {
                    Label(l10n.t("Re-discover", "重新扫描"), systemImage: "arrow.clockwise")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.borderless)

                Button {
                    store.addRootFolderInteractive()
                } label: {
                    Label(l10n.t("Add Folder", "添加目录"), systemImage: "plus")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if store.watchedRoots.isEmpty {
                Text(l10n.t(
                    "No root folders configured. Add a workspace folder to discover .trellis projects.",
                    "尚未配置监听根目录。请添加工作区文件夹以自动发现 .trellis 项目。"
                ))
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
                                    .frame(width: 22, height: 20)
                            }
                            .buttonStyle(InteractiveSurfaceButtonStyle(cornerRadius: 4))
                            .help(l10n.t("Remove watched folder", "移除监听目录"))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                        )
                    }
                }
            }

            if !store.projects.isEmpty {
                Text(l10n.t(
                    "\(store.projects.count) Trellis \(store.projects.count == 1 ? "project" : "projects") discovered",
                    "已发现 \(store.projects.count) 个 Trellis 项目"
                ))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Agent Hooks

    private func agentHooksSection(l10n: L10n) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle(l10n.t("Agent Hooks", "Agent Hook 集成"))
                Spacer()
                Button {
                    store.refreshHookStatuses()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(InteractiveSurfaceButtonStyle(cornerRadius: 5))
                .help(l10n.t("Refresh hook install status", "刷新 Hook 安装状态"))
            }

            VStack(spacing: 5) {
                ForEach(store.hookStatuses) { status in
                    hookRow(status, l10n: l10n)
                }
            }
        }
    }

    private func hookRow(_ status: AgentHookStatusInfo, l10n: L10n) -> some View {
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
                        text: status.installed
                            ? l10n.t("Installed", "已安装")
                            : (status.isSupported ? l10n.t("Not Installed", "未安装") : l10n.t("Auto", "自动")),
                        color: status.installed ? .green : (status.isSupported ? .secondary : .blue)
                    )
                }

                Text(status.detail ?? HUDVisuals.abbreviateHome(status.configPath))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
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
                        Text(status.installed ? l10n.t("Remove", "移除") : l10n.t("Install", "安装"))
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        )
    }

    // MARK: - Keyboard Shortcuts

    private func shortcutsSection(l10n: L10n) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(l10n.t("Shortcuts", "快捷键"))

            shortcutRow(label: l10n.t("Toggle Workbench", "展开 / 收起工作台"), keys: "⌘⌥T")
            shortcutRow(label: l10n.t("Switch Notch / Edge Pill", "切换刘海 / 吸边胶囊"), keys: "⌘⌥M")
            shortcutRow(label: l10n.t("Collapse Workbench", "收起工作台"), keys: "Esc")
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
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
