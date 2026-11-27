import AppKit
import SwiftUI
import TrellisCore

/// Compact draggable macOS floating pill docked magnetically to a screen edge (Mode 2: Edge-Docked Pill).
/// Rendered strictly inside `ScreenGeometry.pillShadowPadding` transparent window margin with an adaptive
/// opaque capsule surface (no borderless `Material` corner clipping), and dragged smoothly via AppKit screen-space
/// mouse tracking in `FirstMouseHostingView` (zero ghosting trails).
public struct EdgePillAmbientView: View {
    public let store: HUDStore

    @State private var pulsePhase: Bool = false

    public init(store: HUDStore) {
        self.store = store
    }

    public var body: some View {
        let loc = store.l10n
        HStack(spacing: 8) {
            statusDot

            VStack(alignment: .leading, spacing: 0.5) {
                Text(store.ambientPhaseLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(store.globalStatus.isAttentionRequired ? statusColor : .primary)
                    .lineLimit(1)
                Text(store.ambientTaskTitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 2)

            if store.attentionCount > 0 {
                HStack(spacing: 2.5) {
                    Image(systemName: store.globalStatus == .failed ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                        .font(.system(size: 8.5, weight: .bold))
                    Text("\(store.attentionCount)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(statusColor))
            } else if store.activeAgentCount > 0 {
                HStack(spacing: 2.5) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(statusColor)
                    Text("\(store.activeAgentCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
        .padding(.horizontal, 12)
        .frame(width: ScreenGeometry.edgePillSize.width, height: ScreenGeometry.edgePillSize.height)
        .background(
            Capsule()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
        )
        .overlay(
            Capsule()
                .strokeBorder(borderColor, lineWidth: store.globalStatus.isAttentionRequired ? 1.15 : 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 5, x: 0, y: 2)
        .padding(ScreenGeometry.pillShadowPadding)
        .contentShape(Capsule())
        .contextMenu {
            Button(loc.t("Open Workbench (⌘⌥T)", "打开工作台 (⌘⌥T)")) {
                store.expand()
            }
            Button(loc.t("Switch to Notch HUD (⌘⌥M)", "切换到刘海 HUD (⌘⌥M)")) {
                store.setPresentationMode(.notch)
            }
            Divider()
            Button(loc.t("Snap Left", "吸附左侧")) { store.setEdgeAnchor(.left) }
            Button(loc.t("Snap Right", "吸附右侧")) { store.setEdgeAnchor(.right) }
            Button(loc.t("Snap Bottom Left", "吸附左下")) { store.setEdgeAnchor(.bottomLeft) }
            Button(loc.t("Snap Bottom Right", "吸附右下")) { store.setEdgeAnchor(.bottomRight) }
            Divider()
            Button(loc.t("Refresh", "刷新")) { store.refreshAll() }
        }
        .onAppear {
            syncBreathingAnimation()
        }
        .onChange(of: isBreathing) { _, _ in
            syncBreathingAnimation()
        }
    }

    private func syncBreathingAnimation() {
        if isBreathing {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulsePhase = true
            }
        } else {
            withAnimation(.linear(duration: 0.15)) {
                pulsePhase = false
            }
        }
    }

    private var statusDot: some View {
        ZStack {
            if isBreathing {
                Circle()
                    .fill(statusColor.opacity(pulsePhase ? 0.38 : 0.12))
                    .frame(width: 13, height: 13)
                    .scaleEffect(pulsePhase ? 1.25 : 0.85)
            }
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
        }
        .frame(width: 13, height: 13)
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
            return Color(red: 0.24, green: 0.80, blue: 0.56)
        case .done:
            return Color(red: 0.30, green: 0.70, blue: 0.96)
        case .stale, .idle:
            return .secondary.opacity(0.6)
        }
    }

    private var borderColor: Color {
        if store.globalStatus.isAttentionRequired {
            return statusColor.opacity(0.8)
        }
        return Color(nsColor: .separatorColor).opacity(0.75)
    }
}
