import AppKit
import Carbon
import Foundation
import TrellisCore
import UserNotifications

/// Main macOS application delegate:
/// - Runs as `.accessory` (no Dock icon)
/// - Owns `HUDStore`, `HUDPanelController`, `FSEventsWatcher`, `HUDUnixSocketServer`, optional `NSStatusItem`
/// - Registers Carbon global hotkeys `⌘⌥T` (toggle workbench) and `⌘⌥M` (switch Notch ↔ Edge Pill)
/// - Emits native `UNUserNotificationCenter` alerts when an agent requires attention (bundle-guarded)
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: HUDStore
    private var panelController: HUDPanelController?
    private var fsWatcher: FSEventsWatcher?
    private var socketServer: HUDUnixSocketServer?
    private var statusItem: NSStatusItem?
    private var stalePruneTimer: Timer?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandlerRef: EventHandlerRef?

    fileprivate static weak var sharedDelegate: AppDelegate?

    private static let hotKeySignature: OSType = 0x54524844 // 'TRHD'
    private static let hotKeyToggleID: UInt32 = 1
    private static let hotKeyModeID: UInt32 = 2

    public override init() {
        self.store = HUDStore()
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Self.sharedDelegate = self
        NSApp.setActivationPolicy(.accessory)

        wireStoreServices()

        let controller = HUDPanelController(store: store)
        self.panelController = controller
        controller.show()

        if store.showMenuBarIcon {
            installStatusItem()
        }

        startFileWatcher()
        startSocketServer()
        registerGlobalHotKeys()
        requestNotificationAuthorizationIfBundled()
        startStalePruneTimer()

        store.refreshHookStatuses()
        store.refreshAll()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        stalePruneTimer?.invalidate()
        stalePruneTimer = nil
        panelController?.teardown()
        fsWatcher?.stop()
        socketServer?.stop()
        unregisterGlobalHotKeys()
    }

    // MARK: Wiring

    private func wireStoreServices() {
        store.onMenuBarVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            if visible {
                self.installStatusItem()
            } else {
                self.removeStatusItem()
            }
        }

        store.onLanguageChanged = { [weak self] _ in
            guard let self, self.statusItem != nil else { return }
            self.rebuildStatusMenu()
        }

        store.onWatchedPathsChanged = { [weak self] paths in
            self?.fsWatcher?.updatePaths(paths)
        }

        store.onAttentionAlert = { [weak self] session in
            self?.postAttentionNotification(for: session)
        }

        store.onJumpToTerminal = { [weak self] agent, projectPath in
            guard let self else { return }
            if let appName = TerminalJumper.jump(agent: agent, projectPath: projectPath) {
                self.store.showToast(self.store.l10n.t("Switched to \(appName)", "已切换到 \(appName)"))
            } else {
                self.store.showToast(
                    self.store.l10n.t("No matching terminal or IDE running", "未找到运行中的终端或 IDE"),
                    isError: true
                )
            }
        }
    }

    // MARK: Services

    private func startFileWatcher() {
        let watcher = FSEventsWatcher(debounceInterval: 0.30) { [weak self] kind in
            Task { @MainActor in
                guard let self else { return }
                switch kind {
                case .channel:
                    self.store.refreshChannelsOnly()
                case .workspace, .both:
                    self.store.refreshAll()
                }
            }
        }
        watcher.updatePaths(store.projects.map { "\($0.path)/.trellis" })
        self.fsWatcher = watcher
    }

    private func startSocketServer() {
        let server = HUDUnixSocketServer { [weak self] events in
            Task { @MainActor in
                guard let self else { return }
                for event in events {
                    self.store.ingestHookEvent(event)
                }
            }
        }
        server.start()
        self.socketServer = server
    }

    private func startStalePruneTimer() {
        stalePruneTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.store.pruneStaleSessions()
            }
        }
    }

    // MARK: Optional Menu Bar Icon (`NSStatusItem`)

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "point.3.connected.trianglepath.dotted",
                accessibilityDescription: "Trellis HUD"
            )
            button.image?.isTemplate = true
        }
        self.statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        guard let item = statusItem else { return }
        let loc = store.l10n
        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: loc.t("Show / Hide Workbench", "显示 / 隐藏工作台"),
            action: #selector(menuToggleWorkbench),
            keyEquivalent: "t"
        )
        toggleItem.keyEquivalentModifierMask = [.command, .option]
        toggleItem.target = self
        menu.addItem(toggleItem)

        let modeItem = NSMenuItem(
            title: loc.t("Switch Notch / Edge Pill", "切换刘海 / 吸边胶囊"),
            action: #selector(menuSwitchMode),
            keyEquivalent: "m"
        )
        modeItem.keyEquivalentModifierMask = [.command, .option]
        modeItem.target = self
        menu.addItem(modeItem)

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(
            title: loc.t("Refresh", "刷新"),
            action: #selector(menuRefresh),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: loc.t("Quit Trellis HUD", "退出 Trellis HUD"),
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
    }

    private func removeStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func menuToggleWorkbench() {
        store.toggleExpanded()
    }

    @objc private func menuSwitchMode() {
        store.togglePresentationMode()
    }

    @objc private func menuRefresh() {
        store.refreshAll()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: Carbon Global Hotkeys (`⌘⌥T` and `⌘⌥M`, avoiding browser/IDE `⌘⇧T` Reopen Tab conflict)

    private func registerGlobalHotKeys() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, eventRef, _ in
            guard let eventRef else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppDelegate.sharedDelegate?.handleHotKey(id: id)
                }
            }
            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            nil,
            &hotKeyHandlerRef
        )
        if installStatus != noErr {
            fputs("[TrellisHUD] InstallEventHandler failed with OSStatus \(installStatus)\n", stderr)
        }

        let modifiers = UInt32(cmdKey | optionKey)

        // ⌘⌥T -> Toggle Workbench (kVK_ANSI_T = 17)
        var toggleRef: EventHotKeyRef?
        let toggleID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyToggleID)
        let toggleStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            modifiers,
            toggleID,
            GetApplicationEventTarget(),
            0,
            &toggleRef
        )
        if toggleStatus == noErr, let toggleRef {
            hotKeyRefs.append(toggleRef)
        } else {
            fputs("[TrellisHUD] RegisterEventHotKey (⌘⌥T) failed with OSStatus \(toggleStatus)\n", stderr)
        }

        // ⌘⌥M -> Switch Notch / Edge Pill (kVK_ANSI_M = 46)
        var modeRef: EventHotKeyRef?
        let modeID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyModeID)
        let modeStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            modifiers,
            modeID,
            GetApplicationEventTarget(),
            0,
            &modeRef
        )
        if modeStatus == noErr, let modeRef {
            hotKeyRefs.append(modeRef)
        } else {
            fputs("[TrellisHUD] RegisterEventHotKey (⌘⌥M) failed with OSStatus \(modeStatus)\n", stderr)
        }
    }

    private func unregisterGlobalHotKeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handler = hotKeyHandlerRef {
            RemoveEventHandler(handler)
            hotKeyHandlerRef = nil
        }
    }

    fileprivate func handleHotKey(id: UInt32) {
        switch id {
        case Self.hotKeyToggleID:
            store.toggleExpanded()
        case Self.hotKeyModeID:
            store.togglePresentationMode()
        default:
            break
        }
    }

    // MARK: Native Notifications (strictly guarded for raw executable runs)

    private var canUseUserNotifications: Bool {
        guard let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty else {
            return false
        }
        return Bundle.main.bundlePath.hasSuffix(".app")
    }

    private func requestNotificationAuthorizationIfBundled() {
        guard canUseUserNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                fputs("[TrellisHUD] notification authorization error: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private func postAttentionNotification(for session: AgentSessionState) {
        guard canUseUserNotifications else { return }
        let loc = store.l10n
        let content = UNMutableNotificationContent()
        content.title = "\(session.agent.displayName) · \(loc.statusLabel(session.status))"
        let projectName = URL(fileURLWithPath: session.projectPath).lastPathComponent
        let detail = session.activity ?? session.toolName ?? loc.t("Requires your attention", "需要你的确认或介入")
        content.body = "\(projectName): \(detail)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "trellis-hud.\(session.sessionId).\(Int(session.updatedAt.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                fputs("[TrellisHUD] notification delivery error: \(error.localizedDescription)\n", stderr)
            }
        }
    }
}
