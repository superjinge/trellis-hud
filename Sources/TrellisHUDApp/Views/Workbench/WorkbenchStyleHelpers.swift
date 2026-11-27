import AppKit
import Foundation
import SwiftUI
import TrellisCore

// MARK: - Shared Native Visual Helpers (Zero Per-Render Formatter Allocations)

@MainActor
enum HUDVisuals {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let yearMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f
    }()

    static func color(for status: RuntimeStatus) -> Color {
        switch status {
        case .waitingPermission: return .orange
        case .waitingQuestion: return .orange
        case .failed: return .red
        case .working: return .blue
        case .done: return .green
        case .stale: return .secondary
        case .idle: return .secondary
        }
    }

    static func icon(for status: RuntimeStatus) -> String {
        switch status {
        case .waitingPermission: return "hand.raised.fill"
        case .waitingQuestion: return "questionmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .working: return "bolt.fill"
        case .done: return "checkmark.circle.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .idle: return "moon.zzz"
        }
    }

    static func color(for outcome: ActivityOutcome) -> Color {
        switch outcome {
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        case .waiting: return .orange
        case .info: return .secondary
        }
    }

    static func color(for lifecycle: ChannelWorkerLifecycle) -> Color {
        switch lifecycle {
        case .starting: return .blue
        case .running: return .green
        case .done: return .secondary
        case .error, .crashed: return .red
        case .killed: return .orange
        }
    }

    static func color(for changeKind: GitChangeKind) -> Color {
        switch changeKind {
        case .added: return .green
        case .modified: return .orange
        case .deleted: return .red
        case .renamed: return .blue
        case .untracked: return .secondary
        case .conflicted: return .pink
        }
    }

    static func shortBadge(for changeKind: GitChangeKind) -> String {
        switch changeKind {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        case .conflicted: return "U"
        }
    }

    static func icon(for agent: AgentKind) -> String {
        switch agent {
        case .claude: return "sparkles"
        case .codex: return "terminal"
        case .cursor: return "cursorarrow.rays"
        case .pi: return "pi"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .dsh: return "cpu"
        case .antigravity: return "atom"
        case .unknown: return "circle.grid.2x2"
        }
    }

    static func displayName(for platform: MemoryPlatform, l10n: L10n) -> String {
        switch platform {
        case .antigravity: return "Antigravity"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .devin: return "Devin"
        case .grok: return "Grok"
        case .opencode: return "OpenCode"
        case .pi: return "Pi"
        case .zcode: return "Zcode"
        case .unknown: return l10n.t("Other", "其他")
        }
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    static func shortTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func shortDate(_ date: Date?) -> String {
        guard let date, date != .distantPast else { return "—" }
        return dateTimeFormatter.string(from: date)
    }

    static func yearMonth(_ date: Date) -> String {
        yearMonthFormatter.string(from: date)
    }

    static func relativeTime(_ date: Date?, l10n: L10n) -> String {
        guard let date, date != .distantPast else { return "—" }
        return l10n.relativeTime(date)
    }
}

// MARK: - Shared Task Document Ordering (Used by DocsSpecTabView & HistoryTabView)

struct TaskDocTabItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let label: String
    let icon: String
}

func orderedTaskDocs(for task: TaskSnapshot, l10n: L10n) -> [TaskDocTabItem] {
    let paths = task.artifacts.documentPaths
    var ordered: [TaskDocTabItem] = []
    var consumed = Set<String>()

    func appendIfPresent(_ target: String, label: String, icon: String) {
        if let match = paths.first(where: { $0.lowercased() == target.lowercased() }) {
            ordered.append(.init(path: match, label: label, icon: icon))
            consumed.insert(match)
        }
    }

    appendIfPresent("prd.md", label: l10n.t("PRD", "需求 PRD"), icon: "doc.text.fill")
    appendIfPresent("design.md", label: l10n.t("Design", "设计"), icon: "rectangle.3.group")
    appendIfPresent("implement.md", label: l10n.t("Implement", "实施计划"), icon: "hammer")

    let researchDocs = paths.filter {
        !consumed.contains($0) && $0.lowercased().contains("research")
    }.sorted()
    for doc in researchDocs {
        let shortName = URL(fileURLWithPath: doc).deletingPathExtension().lastPathComponent
        let base = l10n.t("Research", "调研")
        let label = researchDocs.count == 1 ? base : "\(base): \(shortName)"
        ordered.append(.init(path: doc, label: label, icon: "magnifyingglass.circle"))
        consumed.insert(doc)
    }

    for doc in paths where !consumed.contains(doc) {
        ordered.append(.init(path: doc, label: doc, icon: "doc.plaintext"))
    }

    return ordered
}

// MARK: - Full-Bounds Hit-Testable Interactive Button Style (Fixes Dead Click Zones)

struct InteractiveSurfaceButtonStyle: ButtonStyle {
    var isSelected: Bool = false
    var isCapsule: Bool = false
    var cornerRadius: CGFloat = 7
    var baseFill: Color = .clear
    var selectedFill: Color = Color.accentColor.opacity(0.18)
    var selectedBorder: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
        InteractiveSurfaceButtonBody(
            configuration: configuration,
            isSelected: isSelected,
            isCapsule: isCapsule,
            cornerRadius: cornerRadius,
            baseFill: baseFill,
            selectedFill: selectedFill,
            selectedBorder: selectedBorder
        )
    }
}

private struct InteractiveSurfaceButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    let isCapsule: Bool
    let cornerRadius: CGFloat
    let baseFill: Color
    let selectedFill: Color
    let selectedBorder: Color

    @State private var isHovered = false

    var body: some View {
        let fill: Color = {
            if configuration.isPressed {
                return isSelected ? selectedFill.opacity(1.25) : Color.primary.opacity(0.14)
            }
            if isSelected {
                return selectedFill
            }
            if isHovered {
                return Color.primary.opacity(0.09)
            }
            return baseFill
        }()

        Group {
            if isCapsule {
                configuration.label
                    .background(fill, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(isSelected ? selectedBorder : Color.clear, lineWidth: 0.75)
                    )
                    .contentShape(Capsule())
            } else {
                configuration.label
                    .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(isSelected ? selectedBorder : Color.clear, lineWidth: 0.75)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .opacity(configuration.isPressed ? 0.85 : 1.0)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Reusable Native Card & Pill Components (Generic, High-Contrast)

struct WorkbenchCard<Trailing: View, Content: View>: View {
    let title: String?
    let systemImage: String?
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        systemImage: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    trailing()
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.82),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.75)
        )
    }
}

extension WorkbenchCard where Trailing == EmptyView {
    init(
        title: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = { EmptyView() }
        self.content = content
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 3.5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6.5)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.15), in: Capsule())
    }
}

struct EmptyStatePlaceholder: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.88))
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Draggable & Collapsible Split View

struct DraggableSplitView<Sidebar: View, Detail: View>: View {
    @AppStorage private var storedWidth: Double
    let minWidth: CGFloat
    let maxWidth: CGFloat
    @Binding var isSidebarCollapsed: Bool
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    @State private var dragStartWidth: CGFloat?
    @State private var isHoveringDivider = false
    @State private var isDraggingDivider = false
    @State private var cursorPushed = false

    init(
        storageKey: String,
        defaultWidth: CGFloat = 220,
        minWidth: CGFloat = 170,
        maxWidth: CGFloat = 360,
        isSidebarCollapsed: Binding<Bool>,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self._storedWidth = AppStorage(wrappedValue: Double(defaultWidth), storageKey)
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self._isSidebarCollapsed = isSidebarCollapsed
        self.sidebar = sidebar
        self.detail = detail
    }

    private var clampedWidth: CGFloat {
        min(max(CGFloat(storedWidth), minWidth), maxWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            if !isSidebarCollapsed {
                sidebar()
                    .frame(width: clampedWidth)
                    .frame(maxHeight: .infinity)

                splitDivider
            }

            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .coordinateSpace(name: "DraggableSplitSpace")
        .onDisappear {
            popCursorIfNeeded()
        }
    }

    private var splitDivider: some View {
        ZStack {
            Rectangle()
                .fill(
                    (isHoveringDivider || isDraggingDivider)
                        ? Color.accentColor.opacity(0.75)
                        : Color(nsColor: .separatorColor).opacity(0.55)
                )
                .frame(width: (isHoveringDivider || isDraggingDivider) ? 2 : 1)
        }
        .frame(width: 6)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringDivider = hovering
            updateResizeCursor()
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("DraggableSplitSpace"))
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = clampedWidth
                        isDraggingDivider = true
                        updateResizeCursor()
                    }
                    let base = dragStartWidth ?? clampedWidth
                    let proposed = min(max(base + value.translation.width, minWidth), maxWidth)
                    storedWidth = Double(proposed)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                    isDraggingDivider = false
                    updateResizeCursor()
                }
        )
    }

    private func updateResizeCursor() {
        let shouldShow = isHoveringDivider || isDraggingDivider
        if shouldShow && !cursorPushed {
            NSCursor.resizeLeftRight.push()
            cursorPushed = true
        } else if !shouldShow && cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    private func popCursorIfNeeded() {
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

// MARK: - Subtle Bottom-Right Window Resize Grip Affordance

struct ResizeGripAffordance: View {
    var body: some View {
        Canvas { context, size in
            let stroke = Color.secondary.opacity(0.45)
            let offsets: [CGFloat] = [3.5, 7.5, 11.5]
            for offset in offsets {
                var path = Path()
                path.move(to: CGPoint(x: size.width - offset, y: size.height - 1.5))
                path.addLine(to: CGPoint(x: size.width - 1.5, y: size.height - offset))
                context.stroke(path, with: .color(stroke), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            }
        }
        .frame(width: 14, height: 14)
        .padding(4)
        .allowsHitTesting(false)
    }
}
