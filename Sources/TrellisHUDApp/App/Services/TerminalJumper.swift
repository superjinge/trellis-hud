import AppKit
import Foundation
import TrellisCore

/// Focus-jumps cleanly to the running terminal or IDE corresponding to the active AI agent.
@MainActor
public enum TerminalJumper {
    private static let terminalBundleIds: [String] = [
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.apple.Terminal",
    ]

    private static let ideBundleIds: [String] = [
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.google.antigravity",        // Antigravity
        "com.microsoft.VSCode",
    ]

    /// Activates the best matching running application for `agent`.
    /// Returns the localized app name if activation succeeded.
    @discardableResult
    public static func jump(agent: AgentKind?, projectPath: String? = nil) -> String? {
        let orderedBundles = candidateBundles(for: agent)
        let running = NSWorkspace.shared.runningApplications

        for bundleId in orderedBundles {
            if let app = running.first(where: { $0.bundleIdentifier == bundleId && !$0.isTerminated }) {
                app.activate()
                return app.localizedName ?? bundleId
            }
        }

        // Secondary match by process name for apps whose bundle ID varies (e.g. Antigravity / Cursor nightly)
        if let agent {
            let nameHints = localizedNameHints(for: agent)
            for hint in nameHints {
                if let app = running.first(where: {
                    ($0.localizedName?.localizedCaseInsensitiveContains(hint) ?? false) && !$0.isTerminated
                }) {
                    app.activate()
                    return app.localizedName ?? hint
                }
            }
        }

        // Fallback: open existing project directory in Terminal.app if nothing matched
        if let projectPath, FileManager.default.fileExists(atPath: projectPath) {
            let url = URL(fileURLWithPath: projectPath)
            if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.open([url], withApplicationAt: terminalURL, configuration: config)
                return "Terminal"
            }
        }

        return nil
    }

    private static func candidateBundles(for agent: AgentKind?) -> [String] {
        switch agent {
        case .cursor:
            return ["com.todesktop.230313mzl4w4u92"] + terminalBundleIds + ideBundleIds
        case .antigravity:
            return ["com.google.antigravity"] + ideBundleIds + terminalBundleIds
        case .claude, .codex, .pi, .opencode, .dsh:
            return terminalBundleIds + ideBundleIds
        case .unknown, .none:
            return terminalBundleIds + ideBundleIds
        }
    }

    private static func localizedNameHints(for agent: AgentKind) -> [String] {
        switch agent {
        case .cursor: return ["Cursor"]
        case .antigravity: return ["Antigravity"]
        case .claude, .codex, .pi, .opencode, .dsh:
            return ["Ghostty", "Warp", "iTerm2", "Terminal", "Cursor", "Code"]
        case .unknown:
            return ["Ghostty", "Warp", "iTerm2", "Terminal"]
        }
    }
}
