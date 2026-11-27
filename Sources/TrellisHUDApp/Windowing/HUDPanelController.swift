import AppKit
import SwiftUI
import TrellisCore

/// Borderless, non-activating floating `NSPanel` that never steals focus while collapsed,
/// and smoothly accepts keyboard focus (e.g., History search & Escape) when expanded.
public final class HUDPanel: NSPanel {
    public var allowKeyFocus: Bool = false

    public override var canBecomeKey: Bool { allowKeyFocus }
    public override var canBecomeMain: Bool { false }

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
    }
}

/// Hosts the dual-mode HUD window (True Notch HUD ↔ Edge-Docked Floating Pill)
/// and coordinates smooth collapsed ↔ expanded Workbench transitions.
@MainActor
public final class HUDPanelController {
    private let store: HUDStore
    private let panel: HUDPanel
    private let hostingView: NSHostingView<AnyView>

    private var hoverExpandTask: Task<Void, Never>?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var dragOrigin: NSPoint?

    public init(store: HUDStore) {
        self.store = store
        let screen = ScreenGeometry.activeScreen() ?? NSScreen.screens.first
        let initialFrame: NSRect
        if let screen {
            initialFrame = ScreenGeometry.collapsedFrame(
                mode: store.presentationMode,
                anchor: store.edgeAnchor,
                verticalRatio: store.edgeVerticalRatio,
                on: screen
            )
        } else {
            initialFrame = NSRect(x: 200, y: 200, width: 248, height: 28)
        }

        self.panel = HUDPanel(contentRect: initialFrame)
        self.hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        self.hostingView.frame = NSRect(origin: .zero, size: initialFrame.size)
        self.hostingView.autoresizingMask = [.width, .height]
        self.panel.contentView = self.hostingView

        bindStoreCallbacks()
        observeScreenChanges()
        refreshRootView()
        panel.orderFrontRegardless()
    }

    public func show() {
        updatePanelFrame(animated: false)
        panel.orderFrontRegardless()
    }

    public func hide() {
        hoverExpandTask?.cancel()
        removeInteractionMonitors()
        panel.orderOut(nil)
    }

    private func bindStoreCallbacks() {
        store.onPresentationModeChanged = { [weak self] _ in
            guard let self else { return }
            self.hoverExpandTask?.cancel()
            self.refreshRootView()
            self.updatePanelFrame(animated: true)
        }

        store.onExpansionChanged = { [weak self] expanded in
            guard let self else { return }
            self.hoverExpandTask?.cancel()
            self.panel.allowKeyFocus = expanded
            self.refreshRootView()
            self.updatePanelFrame(animated: true)
            if expanded {
                self.installInteractionMonitors()
                self.panel.orderFrontRegardless()
            } else {
                self.removeInteractionMonitors()
            }
        }

        store.onEdgeAnchorChanged = { [weak self] _ in
            self?.updatePanelFrame(animated: true)
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRootView()
                self?.updatePanelFrame(animated: false)
            }
        }
    }

    private func refreshRootView() {
        let screen = currentTargetScreen()
        let metrics = screen.map { ScreenGeometry.notchMetrics(for: $0) }
            ?? ScreenGeometry.NotchMetrics(
                hasHardwareNotch: false,
                notchWidth: 0,
                notchHeight: 28,
                screenFrame: panel.frame,
                visibleFrame: panel.frame
            )

        let root = HUDRootContainerView(
            store: store,
            metrics: metrics,
            onNotchHoverChanged: { [weak self] hovering in
                self?.handleNotchHover(hovering)
            },
            onAmbientTap: { [weak self] in
                self?.store.toggleExpanded()
            },
            onPillDragDelta: { [weak self] delta in
                self?.handlePillDragDelta(delta)
            },
            onPillDragEnd: { [weak self] in
                self?.handlePillDragEnd()
            }
        )
        hostingView.rootView = AnyView(root)
    }

    private func currentTargetScreen() -> NSScreen? {
        if let panelScreen = panel.screen {
            return panelScreen
        }
        return ScreenGeometry.activeScreen()
    }

    private func updatePanelFrame(animated: Bool) {
        guard let screen = currentTargetScreen() ?? NSScreen.screens.first else { return }
        let target: NSRect
        if store.isExpanded {
            target = ScreenGeometry.expandedFrame(
                mode: store.presentationMode,
                anchor: store.edgeAnchor,
                verticalRatio: store.edgeVerticalRatio,
                on: screen
            )
        } else {
            target = ScreenGeometry.collapsedFrame(
                mode: store.presentationMode,
                anchor: store.edgeAnchor,
                verticalRatio: store.edgeVerticalRatio,
                on: screen
            )
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    // MARK: Notch Hover (150ms anti-jitter delay)

    private func handleNotchHover(_ hovering: Bool) {
        store.isHovered = hovering
        hoverExpandTask?.cancel()
        guard store.presentationMode == .notch, hovering, !store.isExpanded else { return }
        hoverExpandTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.store.isHovered, !self.store.isExpanded else { return }
            self.store.expand()
        }
    }

    // MARK: Edge Pill Drag & Magnetic Edge Snap

    private func handlePillDragDelta(_ delta: CGSize) {
        guard store.presentationMode == .edgePill, !store.isExpanded else { return }
        if dragOrigin == nil {
            dragOrigin = panel.frame.origin
        }
        guard let origin = dragOrigin else { return }
        // SwiftUI global DragGesture translation uses top-left Y+, AppKit screen coordinates use bottom-left Y+
        let newOrigin = NSPoint(
            x: origin.x + delta.width,
            y: origin.y - delta.height
        )
        panel.setFrameOrigin(newOrigin)
    }

    private func handlePillDragEnd() {
        dragOrigin = nil
        guard store.presentationMode == .edgePill, !store.isExpanded else { return }
        let screen = panel.screen ?? ScreenGeometry.activeScreen() ?? NSScreen.screens.first
        guard let screen else { return }
        let (anchor, ratio) = ScreenGeometry.snapAnchor(for: panel.frame, on: screen)
        store.setEdgeVerticalRatio(ratio)
        if store.edgeAnchor != anchor {
            store.setEdgeAnchor(anchor)
        } else {
            updatePanelFrame(animated: true)
        }
    }

    // MARK: Click-Outside & Escape Collapse Monitors

    private func installInteractionMonitors() {
        removeInteractionMonitors()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.store.isExpanded, !self.store.isSettingsOpen else { return }
                let clickPoint = NSEvent.mouseLocation
                if !self.panel.frame.contains(clickPoint) {
                    self.store.collapse()
                }
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in
                    guard let self else { return }
                    if self.store.isSettingsOpen {
                        self.store.isSettingsOpen = false
                    } else if self.store.isExpanded {
                        self.store.collapse()
                    }
                }
                return nil
            }
            return event
        }
    }

    private func removeInteractionMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }
}

/// Switches smoothly between collapsed ambient surface (Notch or Edge Pill) and expanded `WorkbenchContainerView`.
private struct HUDRootContainerView: View {
    let store: HUDStore
    let metrics: ScreenGeometry.NotchMetrics
    let onNotchHoverChanged: (Bool) -> Void
    let onAmbientTap: () -> Void
    let onPillDragDelta: (CGSize) -> Void
    let onPillDragEnd: () -> Void

    var body: some View {
        ZStack {
            if store.isExpanded {
                WorkbenchContainerView(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                switch store.presentationMode {
                case .notch:
                    NotchAmbientView(
                        store: store,
                        metrics: metrics,
                        onHoverChanged: onNotchHoverChanged,
                        onTap: onAmbientTap
                    )
                    .transition(.opacity)
                case .edgePill:
                    EdgePillAmbientView(
                        store: store,
                        onTap: onAmbientTap,
                        onDragDelta: onPillDragDelta,
                        onDragEnd: onPillDragEnd
                    )
                    .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: store.isExpanded)
        .animation(.easeInOut(duration: 0.18), value: store.presentationMode)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
