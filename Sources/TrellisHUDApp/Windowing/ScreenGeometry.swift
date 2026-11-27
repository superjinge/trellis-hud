import AppKit
import Foundation
import TrellisCore

/// Computes exact screen geometry for both True Notch HUD and Edge-Docked Floating Pill modes.
@MainActor
public struct ScreenGeometry: Sendable {
    public struct NotchMetrics: Equatable, Sendable {
        public let hasHardwareNotch: Bool
        public let notchWidth: CGFloat
        public let notchHeight: CGFloat
        public let screenFrame: NSRect
        public let visibleFrame: NSRect
    }

    public static let defaultWorkbenchSize = NSSize(width: 840, height: 580)
    public static let workbenchSize = defaultWorkbenchSize
    public static let minWorkbenchSize = NSSize(width: 640, height: 420)
    public static let edgePillSize = NSSize(width: 196, height: 34)
    /// Transparent margin around the collapsed Edge Pill so its soft drop-shadow renders cleanly
    /// without ever clipping into 4 gray rectangular corners at the borderless window edge.
    public static let pillShadowPadding: CGFloat = 12
    public static let edgePillWindowSize = NSSize(
        width: edgePillSize.width + pillShadowPadding * 2,
        height: edgePillSize.height + pillShadowPadding * 2
    )
    public static let fallbackTopPillSize = NSSize(width: 248, height: 28)
    public static let notchEarWidth: CGFloat = 112
    public static let edgeMargin: CGFloat = 10

    /// Returns the screen currently under the mouse cursor, falling back to `NSScreen.main`.
    public static func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let underMouse = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return underMouse
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Inspects macOS 12+ `safeAreaInsets` and `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`
    /// to determine whether the given screen has a real hardware camera notch and its exact dimensions.
    public static func notchMetrics(for screen: NSScreen) -> NotchMetrics {
        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            let computedWidth = max(140, screen.frame.width - leftArea.width - rightArea.width)
            return NotchMetrics(
                hasHardwareNotch: true,
                notchWidth: computedWidth,
                notchHeight: topInset,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        return NotchMetrics(
            hasHardwareNotch: false,
            notchWidth: 0,
            notchHeight: fallbackTopPillSize.height,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }

    /// Maximum allowed Workbench window size on the given screen.
    public static func maxWorkbenchSize(on screen: NSScreen) -> NSSize {
        let vf = screen.visibleFrame
        return NSSize(
            width: max(minWorkbenchSize.width, (vf.width - 32).rounded()),
            height: max(minWorkbenchSize.height, (vf.height - 32).rounded())
        )
    }

    /// Computes the visual (non-padded) pill rect on screen for Edge Pill mode.
    public static func visualEdgePillRect(
        anchor: EdgeAnchor,
        verticalRatio: Double,
        on screen: NSScreen
    ) -> NSRect {
        let vf = screen.visibleFrame
        let size = edgePillSize
        let clampedRatio = CGFloat(min(max(verticalRatio, 0.08), 0.92))
        let raw: NSRect
        switch anchor {
        case .left:
            let x = vf.minX + edgeMargin
            let y = vf.minY + (vf.height - size.height) * (1.0 - clampedRatio)
            raw = NSRect(x: x, y: y, width: size.width, height: size.height)
        case .right:
            let x = vf.maxX - size.width - edgeMargin
            let y = vf.minY + (vf.height - size.height) * (1.0 - clampedRatio)
            raw = NSRect(x: x, y: y, width: size.width, height: size.height)
        case .bottomLeft:
            let x = vf.minX + edgeMargin + 8
            let y = vf.minY + edgeMargin
            raw = NSRect(x: x, y: y, width: size.width, height: size.height)
        case .bottomRight:
            let x = vf.maxX - size.width - edgeMargin - 8
            let y = vf.minY + edgeMargin
            raw = NSRect(x: x, y: y, width: size.width, height: size.height)
        }
        return clamp(raw, inside: vf)
    }

    /// Computes collapsed panel frame for the active presentation mode.
    public static func collapsedFrame(
        mode: PresentationMode,
        anchor: EdgeAnchor,
        verticalRatio: Double,
        on screen: NSScreen
    ) -> NSRect {
        switch mode {
        case .notch:
            let metrics = notchMetrics(for: screen)
            if metrics.hasHardwareNotch {
                let totalWidth = metrics.notchWidth + notchEarWidth * 2
                let height = max(metrics.notchHeight, 32)
                let x = metrics.screenFrame.midX - totalWidth / 2
                let y = metrics.screenFrame.maxY - height
                return NSRect(x: x.rounded(), y: y.rounded(), width: totalWidth.rounded(), height: height.rounded())
            } else {
                let size = fallbackTopPillSize
                let x = metrics.visibleFrame.midX - size.width / 2
                let y = metrics.visibleFrame.maxY - size.height - 4
                return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
            }

        case .edgePill:
            let visual = visualEdgePillRect(anchor: anchor, verticalRatio: verticalRatio, on: screen)
            return NSRect(
                x: (visual.minX - pillShadowPadding).rounded(),
                y: (visual.minY - pillShadowPadding).rounded(),
                width: edgePillWindowSize.width,
                height: edgePillWindowSize.height
            )
        }
    }

    /// Computes expanded Workbench panel frame using the persisted/preferred size clamped to screen bounds.
    public static func expandedFrame(
        mode: PresentationMode,
        anchor: EdgeAnchor,
        verticalRatio: Double,
        preferredSize: NSSize = defaultWorkbenchSize,
        on screen: NSScreen
    ) -> NSRect {
        let vf = screen.visibleFrame
        let maxSize = maxWorkbenchSize(on: screen)
        let targetWidth = min(max(preferredSize.width, minWorkbenchSize.width), maxSize.width)
        let targetHeight = min(max(preferredSize.height, minWorkbenchSize.height), maxSize.height)

        switch mode {
        case .notch:
            let metrics = notchMetrics(for: screen)
            let x = metrics.screenFrame.midX - targetWidth / 2
            let topY = metrics.hasHardwareNotch
                ? (metrics.screenFrame.maxY - metrics.notchHeight)
                : (vf.maxY - 6)
            let rect = NSRect(
                x: x.rounded(),
                y: (topY - targetHeight).rounded(),
                width: targetWidth.rounded(),
                height: targetHeight.rounded()
            )
            return clamp(rect, inside: NSRect(
                x: vf.minX + edgeMargin,
                y: vf.minY + edgeMargin,
                width: vf.width - edgeMargin * 2,
                height: (metrics.hasHardwareNotch ? metrics.screenFrame.maxY - vf.minY : vf.height) - edgeMargin
            ))

        case .edgePill:
            let pill = visualEdgePillRect(anchor: anchor, verticalRatio: verticalRatio, on: screen)
            let origin: NSPoint
            switch anchor {
            case .left:
                origin = NSPoint(x: pill.minX, y: pill.midY - targetHeight / 2)
            case .right:
                origin = NSPoint(x: pill.maxX - targetWidth, y: pill.midY - targetHeight / 2)
            case .bottomLeft:
                origin = NSPoint(x: pill.minX, y: pill.minY)
            case .bottomRight:
                origin = NSPoint(x: pill.maxX - targetWidth, y: pill.minY)
            }
            return clamp(
                NSRect(origin: origin, size: NSSize(width: targetWidth, height: targetHeight)),
                inside: vf.insetBy(dx: edgeMargin, dy: edgeMargin)
            )
        }
    }

    /// Determines the nearest magnetic `EdgeAnchor` and vertical ratio when the user finishes dragging the Edge Pill.
    public static func snapAnchor(for pillWindowFrame: NSRect, on screen: NSScreen) -> (EdgeAnchor, Double) {
        let vf = screen.visibleFrame
        let pillFrame = pillWindowFrame.insetBy(dx: pillShadowPadding, dy: pillShadowPadding)
        let midX = pillFrame.midX
        let midY = pillFrame.midY

        let distLeft = abs(pillFrame.minX - vf.minX)
        let distRight = abs(vf.maxX - pillFrame.maxX)
        let distBottom = abs(pillFrame.minY - vf.minY)

        let ratio = 1.0 - Double((midY - vf.minY) / max(1, vf.height))
        let clampedRatio = min(max(ratio, 0.08), 0.92)

        if distBottom < 68 {
            return (midX < vf.midX ? .bottomLeft : .bottomRight, clampedRatio)
        }
        return (distLeft <= distRight ? .left : .right, clampedRatio)
    }

    private static func clamp(_ rect: NSRect, inside bounds: NSRect) -> NSRect {
        var out = rect
        if out.maxX > bounds.maxX { out.origin.x = bounds.maxX - out.width }
        if out.minX < bounds.minX { out.origin.x = bounds.minX }
        if out.maxY > bounds.maxY { out.origin.y = bounds.maxY - out.height }
        if out.minY < bounds.minY { out.origin.y = bounds.minY }
        out.origin.x = out.origin.x.rounded()
        out.origin.y = out.origin.y.rounded()
        return out
    }
}
