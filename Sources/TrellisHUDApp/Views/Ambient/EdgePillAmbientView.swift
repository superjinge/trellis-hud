import SwiftUI
import TrellisCore

/// Compact draggable macOS floating pill docked magnetically to a screen edge (Mode 2: Edge-Docked Pill).
/// Never steals focus; click expands the Workbench anchored adjacent to the pill; drag snaps to nearest edge.
public struct EdgePillAmbientView: View {
    public let store: HUDStore
    public let onTap: () -> Void
    public let onDragDelta: (CGSize) -> Void
    public let onDragEnd: () -> Void

    @State private var pulsePhase: Bool = false
    @State private var isDragging: Bool = false

    public init(
        store: HUDStore,
        onTap: @escaping () -> Void,
        onDragDelta: @escaping (CGSize) -> Void,
        onDragEnd: @escaping () -> Void
    ) {
        self.store = store
        self.onTap = onTap
        self.onDragDelta = onDragDelta
        self.onDragEnd = onDragEnd
    }

    public var body: some View {
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
                .background(Capsule().fill(.primary.opacity(0.08)))
            }
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule()
                .strokeBorder(borderColor, lineWidth: store.globalStatus.isAttentionRequired ? 1.1 : 0.75)
        )
        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 3)
        .scaleEffect(isDragging ? 1.02 : 1.0)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                    isDragging = true
                    onDragDelta(value.translation)
                }
                .onEnded { _ in
                    isDragging = false
                    onDragEnd()
                }
        )
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    if !isDragging {
                        onTap()
                    }
                }
        )
        .contextMenu {
            Button("Open Workbench (⌘⇧T)") {
                store.expand()
            }
            Button("Switch to Notch HUD (⌘⇧M)") {
                store.setPresentationMode(.notch)
            }
            Divider()
            Button("Snap Left") { store.setEdgeAnchor(.left) }
            Button("Snap Right") { store.setEdgeAnchor(.right) }
            Button("Snap Bottom Left") { store.setEdgeAnchor(.bottomLeft) }
            Button("Snap Bottom Right") { store.setEdgeAnchor(.bottomRight) }
            Divider()
            Button("Refresh") { store.refreshAll() }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulsePhase = true
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
            return statusColor.opacity(0.75)
        }
        return Color.primary.opacity(0.16)
    }
}
