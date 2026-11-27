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

    public static let workbenchSize = NSSize(width: 720, height: 520)
    public static let edgePillSize = NSSize(width: 196, height: 34)
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
                // External / non-notch display: sleek centered top pill right under menu bar
                let size = fallbackTopPillSize
                let x = metrics.visibleFrame.midX - size.width / 2
                let y = metrics.visibleFrame.maxY - size.height - 4
                return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
            }

        case .edgePill:
            let vf = screen.visibleFrame
            let size = edgePillSize
            let clampedRatio = CGFloat(min(max(verticalRatio, 0.08), 0.92))
            switch anchor {
            case .left:
                let x = vf.minX + edgeMargin
                let y = vf.minY + (vf.height - size.height) * (1.0 - clampedRatio)
                return clamp(NSRect(x: x, y: y, width: size.width, height: size.height), inside: vf)
            case .right:
                let x = vf.maxX - size.width - edgeMargin
                let y = vf.minY + (vf.height - size.height) * (1.0 - clampedRatio)
                return clamp(NSRect(x: x, y: y, width: size.width, height: size.height), inside: vf)
            case .bottomLeft:
                let x = vf.minX + edgeMargin + 8
                let y = vf.minY + edgeMargin
                return clamp(NSRect(x: x, y: y, width: size.width, height: size.height), inside: vf)
            case .bottomRight:
                let x = vf.maxX - size.width - edgeMargin - 8
                let y = vf.minY + edgeMargin
                return clamp(NSRect(x: x, y: y, width: size.width, height: size.height), inside: vf)
            }
        }
    }

    /// Computes expanded Workbench panel frame, anchored seamlessly to either the Notch or the Edge Pill.
    public static func expandedFrame(
        mode: PresentationMode,
        anchor: EdgeAnchor,
        verticalRatio: Double,
        on screen: NSScreen
    ) -> NSRect {
        let vf = screen.visibleFrame
        let targetWidth = min(workbenchSize.width, vf.width - edgeMargin * 2)
        let targetHeight = min(workbenchSize.height, vf.height - edgeMargin * 2)

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
            let pill = collapsedFrame(mode: .edgePill, anchor: anchor, verticalRatio: verticalRatio, on: screen)
            var origin: NSPoint
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
    public static func snapAnchor(for pillFrame: NSRect, on screen: NSScreen) -> (EdgeAnchor, Double) {
        let vf = screen.visibleFrame
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
