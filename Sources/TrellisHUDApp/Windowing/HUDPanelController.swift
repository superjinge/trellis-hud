import AppKit
import Observation
import SwiftUI
import TrellisCore

/// Borderless, non-activating floating `NSPanel` that never steals focus while collapsed,
/// and smoothly becomes key when expanded so buttons, menus, and text fields respond on the first click.
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
        becomesKeyOnlyIfNeeded = false
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

/// Custom `NSHostingView` that:
/// 1. Accepts first mouse click immediately (`acceptsFirstMouse -> true`) so SwiftUI buttons/tabs never drop click #1.
/// 2. Keeps its CoreAnimation layer strictly transparent (no rectangular backdrop/shadow artifacts).
/// 3. Handles collapsed Edge Pill dragging directly in AppKit screen coordinates (`NSEvent.mouseLocation`)
///    to completely eliminate SwiftUI `DragGesture` coordinate-feedback ghosting.
public final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    public var isEdgePillDraggable: (() -> Bool)?
    public var onEdgePillTapped: (() -> Void)?
    public var onEdgePillDragEnded: (() -> Void)?

    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var didExceedDragThreshold: Bool = false

    public required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isOpaque: Bool { false }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    public override func mouseDown(with event: NSEvent) {
        if event.type == .leftMouseDown, isEdgePillDraggable?() == true, let window {
            dragStartMouse = NSEvent.mouseLocation
            dragStartOrigin = window.frame.origin
            didExceedDragThreshold = false
            return
        }
        super.mouseDown(with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        if let startMouse = dragStartMouse, let startOrigin = dragStartOrigin, let window {
            let current = NSEvent.mouseLocation
            let dx = current.x - startMouse.x
            let dy = current.y - startMouse.y
            if !didExceedDragThreshold, hypot(dx, dy) >= 4.0 {
                didExceedDragThreshold = true
            }
            if didExceedDragThreshold {
                window.setFrameOrigin(NSPoint(
                    x: (startOrigin.x + dx).rounded(),
                    y: (startOrigin.y + dy).rounded()
                ))
            }
            return
        }
        super.mouseDragged(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if dragStartMouse != nil {
            let dragged = didExceedDragThreshold
            dragStartMouse = nil
            dragStartOrigin = nil
            didExceedDragThreshold = false
            if dragged {
                onEdgePillDragEnded?()
            } else {
                onEdgePillTapped?()
            }
            return
        }
        super.mouseUp(with: event)
    }
}

/// Observable holder for screen notch metrics so `HUDPanelController` NEVER tears down `hostingView.rootView`.
@Observable
@MainActor
private final class PanelMetricsState {
    var metrics: ScreenGeometry.NotchMetrics

    init(metrics: ScreenGeometry.NotchMetrics) {
        self.metrics = metrics
    }
}

/// Hosts the dual-mode HUD window (True Notch HUD ↔ Edge-Docked Floating Pill)
/// and coordinates smooth collapsed ↔ expanded Workbench transitions without view-tree teardown.
@MainActor
public final class HUDPanelController {
    private let store: HUDStore
    private let panel: HUDPanel
    private let metricsState: PanelMetricsState
    private let hostingView: FirstMouseHostingView<HUDRootContainerView>

    private var hoverExpandTask: Task<Void, Never>?
    nonisolated(unsafe) private var globalMouseMonitor: Any?
    nonisolated(unsafe) private var localKeyMonitor: Any?
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    private var isModalOpen: Bool = false

    public init(store: HUDStore) {
        self.store = store
        let screen = ScreenGeometry.activeScreen() ?? NSScreen.screens.first
        let initialFrame: NSRect
        let initialMetrics: ScreenGeometry.NotchMetrics
        if let screen {
            initialFrame = ScreenGeometry.collapsedFrame(
                mode: store.presentationMode,
                anchor: store.edgeAnchor,
                verticalRatio: store.edgeVerticalRatio,
                on: screen
            )
            initialMetrics = ScreenGeometry.notchMetrics(for: screen)
        } else {
            initialFrame = NSRect(x: 200, y: 200, width: 248, height: 28)
            initialMetrics = ScreenGeometry.NotchMetrics(
                hasHardwareNotch: false,
                notchWidth: 0,
                notchHeight: 28,
                screenFrame: initialFrame,
                visibleFrame: initialFrame
            )
        }

        self.panel = HUDPanel(contentRect: initialFrame)
        self.metricsState = PanelMetricsState(metrics: initialMetrics)

        let placeholder = HUDRootContainerView(
            store: store,
            metricsState: metricsState,
            onNotchHoverChanged: { _ in },
            onAmbientTap: {}
        )
        self.hostingView = FirstMouseHostingView(rootView: placeholder)
        self.hostingView.frame = NSRect(origin: .zero, size: initialFrame.size)
        self.hostingView.autoresizingMask = [.width, .height]
        self.panel.contentView = self.hostingView

        // Set the permanent root view ONCE with weak-self callbacks; never reassign `rootView` again.
        self.hostingView.rootView = HUDRootContainerView(
            store: store,
            metricsState: metricsState,
            onNotchHoverChanged: { [weak self] hovering in
                self?.handleNotchHover(hovering)
            },
            onAmbientTap: { [weak self] in
                self?.store.toggleExpanded()
            }
        )

        self.hostingView.isEdgePillDraggable = { [weak self] in
            guard let self else { return false }
            return self.store.presentationMode == .edgePill && !self.store.isExpanded
        }
        self.hostingView.onEdgePillTapped = { [weak self] in
            self?.store.toggleExpanded()
        }
        self.hostingView.onEdgePillDragEnded = { [weak self] in
            self?.handlePillDragEnd()
        }

        bindStoreCallbacks()
        observeScreenChanges()
        panel.orderFrontRegardless()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }

    public func teardown() {
        hoverExpandTask?.cancel()
        hoverExpandTask = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        removeInteractionMonitors()
    }

    public func show() {
        updateMetricsForTargetScreen()
        updatePanelFrame(animated: false)
        panel.orderFrontRegardless()
    }

    /// Lowers the HUD panel level temporarily while a system modal (`NSOpenPanel`) is active
    /// so the file picker always appears cleanly in front of the HUD.
    public func setModalSuppressed(_ suppressed: Bool) {
        isModalOpen = suppressed
        panel.level = suppressed ? .floating : .statusBar
    }

    private func bindStoreCallbacks() {
        store.onPresentationModeChanged = { [weak self] _ in
            guard let self else { return }
            self.hoverExpandTask?.cancel()
            self.updateMetricsForTargetScreen()
            self.updatePanelFrame(animated: true)
        }

        store.onExpansionChanged = { [weak self] expanded in
            guard let self else { return }
            self.hoverExpandTask?.cancel()
            self.panel.allowKeyFocus = expanded
            self.updateMetricsForTargetScreen()
            self.updatePanelFrame(animated: true)
            if expanded {
                self.installInteractionMonitors()
                self.panel.makeKeyAndOrderFront(nil)
            } else {
                self.removeInteractionMonitors()
                self.panel.orderFrontRegardless()
            }
        }

        store.onEdgeAnchorChanged = { [weak self] _ in
            self?.updatePanelFrame(animated: true)
        }

        store.onModalPresentationChanged = { [weak self] active in
            self?.setModalSuppressed(active)
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateMetricsForTargetScreen()
                self?.updatePanelFrame(animated: false)
            }
        }
    }

    private func currentTargetScreen() -> NSScreen? {
        if store.presentationMode == .notch {
            return ScreenGeometry.activeScreen() ?? panel.screen ?? NSScreen.screens.first
        }
        return panel.screen ?? ScreenGeometry.activeScreen() ?? NSScreen.screens.first
    }

    private func updateMetricsForTargetScreen() {
        guard let screen = currentTargetScreen() else { return }
        let next = ScreenGeometry.notchMetrics(for: screen)
        if metricsState.metrics != next {
            metricsState.metrics = next
        }
    }

    private func updatePanelFrame(animated: Bool) {
        guard let screen = currentTargetScreen() else { return }
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
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    // MARK: Notch Hover (150ms anti-jitter delay)

    private func handleNotchHover(_ hovering: Bool) {
        if store.isHovered != hovering {
            store.isHovered = hovering
        }
        hoverExpandTask?.cancel()
        guard store.presentationMode == .notch, hovering, !store.isExpanded else { return }
        hoverExpandTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.store.isHovered, !self.store.isExpanded else { return }
            self.store.expand()
        }
    }

    // MARK: Edge Pill Magnetic Snap (AppKit screen-space drag completes here)

    private func handlePillDragEnd() {
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

    private func isClickInsideOwnWindows(_ clickPoint: NSPoint) -> Bool {
        if panel.frame.contains(clickPoint) {
            return true
        }
        // Ignore clicks landing inside SwiftUI popovers, NSMenu popups, or attached sheets belonging to this app
        for window in NSApp.windows where window.isVisible && window !== panel {
            if window.frame.contains(clickPoint) {
                return true
            }
        }
        return false
    }

    private func installInteractionMonitors() {
        removeInteractionMonitors()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.store.isExpanded, !self.store.isSettingsOpen, !self.isModalOpen else {
                    return
                }
                let clickPoint = NSEvent.mouseLocation
                if !self.isClickInsideOwnWindows(clickPoint) {
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

/// Permanent root SwiftUI container hosted inside `FirstMouseHostingView` (never torn down on expand/collapse).
private struct HUDRootContainerView: View {
    let store: HUDStore
    let metricsState: PanelMetricsState
    let onNotchHoverChanged: (Bool) -> Void
    let onAmbientTap: () -> Void

    var body: some View {
        ZStack {
            if store.isExpanded {
                WorkbenchContainerView(store: store)
            } else {
                switch store.presentationMode {
                case .notch:
                    NotchAmbientView(
                        store: store,
                        metrics: metricsState.metrics,
                        onHoverChanged: onNotchHoverChanged,
                        onTap: onAmbientTap
                    )
                case .edgePill:
                    EdgePillAmbientView(store: store)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
