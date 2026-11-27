import SwiftUI
import TrellisCore

/// Sleek matte-black notch-hugging ambient HUD surface (Mode 1: True Notch HUD).
/// On hardware-notch displays, renders subtle left & right ears flanking the camera notch.
/// On non-notch external monitors, degrades gracefully to a 28px centered top pill.
public struct NotchAmbientView: View {
    public let store: HUDStore
    public let metrics: ScreenGeometry.NotchMetrics
    public let onHoverChanged: (Bool) -> Void
    public let onTap: () -> Void

    @State private var pulsePhase: Bool = false

    public init(
        store: HUDStore,
        metrics: ScreenGeometry.NotchMetrics,
        onHoverChanged: @escaping (Bool) -> Void,
        onTap: @escaping () -> Void
    ) {
        self.store = store
        self.metrics = metrics
        self.onHoverChanged = onHoverChanged
        self.onTap = onTap
    }

    public var body: some View {
        Group {
            if metrics.hasHardwareNotch {
                hardwareNotchLayout
            } else {
                fallbackTopPillLayout
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            onHoverChanged(hovering)
        }
        .onTapGesture {
            onTap()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulsePhase = true
            }
        }
    }

    // MARK: Hardware Notch Ears Layout

    private var hardwareNotchLayout: some View {
        HStack(spacing: 0) {
            // Left ear: breathing status LED + real workflow phase
            HStack(spacing: 6) {
                statusDot
                Text(store.ambientPhaseLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(phaseTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(width: ScreenGeometry.notchEarWidth, alignment: .leading)

            // Hardware notch dead-zone spacer
            Color.clear
                .frame(width: metrics.notchWidth)

            // Right ear: attention pill OR active agent count + subtle title
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if store.attentionCount > 0 {
                    attentionPill
                } else if store.activeAgentCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(statusColor)
                        Text("\(store.activeAgentCount)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                } else {
                    Text(store.ambientTaskTitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(width: ScreenGeometry.notchEarWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            NotchWingShape(bottomRadius: 12)
                .fill(Color.black)
        )
        .overlay(
            NotchWingShape(bottomRadius: 12)
                .strokeBorder(borderColor, lineWidth: 0.75)
        )
    }

    // MARK: Non-Notch External Monitor Fallback Top Pill

    private var fallbackTopPillLayout: some View {
        HStack(spacing: 7) {
            statusDot
            Text(store.ambientPhaseLabel)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(phaseTextColor)
                .lineLimit(1)

            Text("·")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.3))

            Text(store.ambientTaskTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if store.attentionCount > 0 {
                attentionPill
            } else if store.activeAgentCount > 0 {
                Text("\(store.activeAgentCount)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.white.opacity(0.14)))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            Capsule()
                .strokeBorder(borderColor, lineWidth: 0.75)
        )
    }

    // MARK: Subcomponents

    private var statusDot: some View {
        ZStack {
            if isBreathing {
                Circle()
                    .fill(statusColor.opacity(pulsePhase ? 0.42 : 0.12))
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulsePhase ? 1.2 : 0.85)
            }
            Circle()
                .fill(statusColor)
                .frame(width: 6.5, height: 6.5)
        }
        .frame(width: 12, height: 12)
    }

    private var attentionPill: some View {
        HStack(spacing: 3) {
            Image(systemName: store.globalStatus == .failed ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                .font(.system(size: 9, weight: .bold))
            Text("\(store.attentionCount)")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(Color.black)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(statusColor)
        )
    }

    private var isBreathing: Bool {
        switch store.globalStatus {
        case .working, .waitingPermission, .waitingQuestion, .failed:
            return true
        case .done, .stale, .idle:
            return false
        }
    }

    private var statusColor: Color {
        switch store.globalStatus {
        case .waitingPermission, .waitingQuestion:
            return Color(red: 1.0, green: 0.72, blue: 0.22)
        case .failed:
            return Color(red: 0.98, green: 0.36, blue: 0.38)
        case .working:
            return Color(red: 0.28, green: 0.84, blue: 0.62)
        case .done:
            return Color(red: 0.36, green: 0.76, blue: 0.98)
        case .stale, .idle:
            return Color.white.opacity(0.45)
        }
    }

    private var phaseTextColor: Color {
        store.globalStatus.isAttentionRequired ? statusColor : .white.opacity(0.92)
    }

    private var borderColor: Color {
        if store.globalStatus.isAttentionRequired {
            return statusColor.opacity(0.55)
        }
        return store.isHovered ? Color.white.opacity(0.22) : Color.white.opacity(0.10)
    }
}

/// Top-flush shape with softly rounded bottom corners so the HUD visually merges with the MacBook notch bezel.
private struct NotchWingShape: InsettableShape {
    var bottomRadius: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> NotchWingShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = min(bottomRadius, min(r.width / 2, r.height))
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        path.addArc(
            center: CGPoint(x: r.maxX - radius, y: r.maxY - radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        path.addArc(
            center: CGPoint(x: r.minX + radius, y: r.maxY - radius),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
