import Foundation
import TrellisCore

/// Zero-dependency bilingual (English / Simplified Chinese) localization helper driven by `TrellisCore.AppLanguage`.
public struct L10n: Sendable, Equatable {
    public let language: AppLanguage
    public let isChinese: Bool

    public init(language: AppLanguage = .system) {
        self.language = language
        switch language {
        case .zhHans:
            self.isChinese = true
        case .en:
            self.isChinese = false
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
            self.isChinese = preferred.hasPrefix("zh")
        }
    }

    /// Picks English or Simplified Chinese text based on resolved language.
    @inline(__always)
    public func t(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }

    // MARK: - Typed Domain Labels

    public func tabTitle(_ tab: WorkbenchTab) -> String {
        switch tab {
        case .flow: return t("Flow", "流程")
        case .live: return t("Live", "实时")
        case .docsSpecs: return t("Docs & Specs", "文档与规范")
        case .history: return t("History", "历史")
        }
    }

    public func phaseLabel(_ phase: WorkflowPhase) -> String {
        switch phase {
        case .explore: return t("Explore", "探索")
        case .plan: return t("Plan", "规划")
        case .implement: return t("Implement", "实施")
        case .check: return t("Check", "校验")
        case .archive: return t("Archive", "归档")
        }
    }

    public func shortPhaseLabel(_ phase: WorkflowPhase) -> String {
        switch phase {
        case .explore: return t("Explore", "探索")
        case .plan: return t("Plan", "规划")
        case .implement: return t("Impl", "实施")
        case .check: return t("Check", "校验")
        case .archive: return t("Archive", "归档")
        }
    }

    public func statusLabel(_ status: RuntimeStatus) -> String {
        switch status {
        case .working: return t("Working", "运行中")
        case .waitingPermission: return t("Needs Approval", "待授权")
        case .waitingQuestion: return t("Waiting", "等待中")
        case .failed: return t("Failed", "失败")
        case .done: return t("Done", "已完成")
        case .stale: return t("Stale", "已静默")
        case .idle: return t("Idle", "空闲")
        }
    }

    public func modeLabel(_ mode: PresentationMode) -> String {
        switch mode {
        case .notch: return t("Notch", "刘海")
        case .edgePill: return t("Edge Pill", "吸边胶囊")
        }
    }

    public func modeFullLabel(_ mode: PresentationMode) -> String {
        switch mode {
        case .notch: return t("Notch HUD", "刘海 HUD")
        case .edgePill: return t("Edge Pill", "吸边胶囊")
        }
    }

    public func edgeAnchorLabel(_ anchor: EdgeAnchor) -> String {
        switch anchor {
        case .left: return t("Left", "左侧")
        case .right: return t("Right", "右侧")
        case .bottomLeft: return t("Bottom Left", "左下")
        case .bottomRight: return t("Bottom Right", "右下")
        }
    }

    public func languageOptionLabel(_ option: AppLanguage) -> String {
        switch option {
        case .system: return t("Follow System", "跟随系统")
        case .zhHans: return "中文"
        case .en: return "English"
        }
    }

    public func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 15 {
            return t("just now", "刚刚")
        }
        if seconds < 60 {
            return t("\(seconds)s ago", "\(seconds)秒前")
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return t("\(minutes)m ago", "\(minutes)分钟前")
        }
        let hours = minutes / 60
        if hours < 24 {
            return t("\(hours)h ago", "\(hours)小时前")
        }
        let days = hours / 24
        if days < 30 {
            return t("\(days)d ago", "\(days)天前")
        }
        let months = max(1, days / 30)
        return t("\(months)mo ago", "\(months)个月前")
    }
}
