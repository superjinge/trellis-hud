import Foundation
import TrellisCore

/// Lightweight zero-AppKit hook CLI (`trellis-card-hook`).
/// Subcommands:
///   - `hook [--agent <kind>] [--event <name>] [--session <id>] [--project <dir>] [--task <dir>]`
///   - `install-hooks [--agent <kind|all>] [--uninstall]`
///   - `status [--json]`
enum TrellisHookCLI {
    static func run(args: [String]) -> Int32 {
        guard let subcommand = args.first else {
            printUsage()
            return 0
        }
        let rest = Array(args.dropFirst())
        switch subcommand {
        case "hook":
            return runHook(args: rest)
        case "install-hooks":
            return runInstallHooks(args: rest)
        case "status":
            return runStatus(args: rest)
        case "-h", "--help", "help":
            printUsage()
            return 0
        default:
            fputs("Unknown subcommand: \(subcommand)\n", stderr)
            printUsage()
            return 1
        }
    }

    private static func runHook(args: [String]) -> Int32 {
        let overrides = parseHookOverrides(args)
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        let input = String(data: stdinData, encoding: .utf8) ?? "{}"

        do {
            let event = try HookEventParser.parsePayload(input, overrides: overrides)
            let store = ConfigStore()
            if !UnixSocketProtocol.sendEvent(event, socketPath: store.socketPath, queueDir: store.inboxDirURL) {
                fputs("[hook] unable to deliver event\n", stderr)
            }
        } catch {
            fputs("[hook] invalid payload: \(error.localizedDescription)\n", stderr)
        }

        // Cursor command hooks expect fail-open JSON `{}` on stdout.
        if overrides.agent?.lowercased() == "cursor" {
            print("{}")
        }
        return 0
    }

    private static func runInstallHooks(args: [String]) -> Int32 {
        var agentArg: String?
        var uninstall = false
        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--agent":
                if idx + 1 < args.count {
                    agentArg = args[idx + 1]
                    idx += 2
                } else {
                    idx += 1
                }
            case "--uninstall":
                uninstall = true
                idx += 1
            default:
                idx += 1
            }
        }

        let installer = HookInstaller()
        let targets: [AgentKind]
        if let raw = agentArg, raw.lowercased() != "all" {
            let kind = AgentKind.from(raw: raw)
            guard kind != .unknown else {
                fputs("Unsupported agent: \(raw)\n", stderr)
                return 1
            }
            targets = [kind]
        } else {
            targets = HookInstaller.supportedAgents
        }

        var hadError = false
        for agent in targets {
            do {
                let path = try installer.install(agent: agent, uninstall: uninstall)
                let verb = uninstall ? "Uninstalled" : "Installed"
                print("\(verb) \(agent.rawValue) -> \(path.path)")
            } catch {
                fputs("Failed \(agent.rawValue): \(error.localizedDescription)\n", stderr)
                hadError = true
            }
        }
        return hadError ? 1 : 0
    }

    private static func runStatus(args: [String]) -> Int32 {
        let asJSON = args.contains("--json")
        let store = ConfigStore()
        let installer = HookInstaller(configStore: store)
        let statuses = installer.allStatuses()

        if asJSON {
            struct Payload: Encodable {
                let configDir: String
                let socketPath: String
                let inboxDir: String
                let hooks: [HookInstallStatus]
            }
            let payload = Payload(
                configDir: store.configDir.path,
                socketPath: store.socketPath,
                inboxDir: store.inboxDirURL.path,
                hooks: statuses
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return 0
        }

        print("Config dir : \(store.configDir.path)")
        print("Socket path: \(store.socketPath)")
        print("Inbox dir  : \(store.inboxDirURL.path)")
        print("")
        for item in statuses {
            let mark = item.installed ? "[installed]" : "[not set]  "
            print("  \(mark) \(item.agent.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(item.configPath)")
        }
        return 0
    }

    private static func parseHookOverrides(_ args: [String]) -> HookOverrides {
        var out = HookOverrides()
        var idx = 0
        while idx < args.count {
            let key = args[idx]
            let value = (idx + 1 < args.count) ? args[idx + 1] : nil
            switch key {
            case "--agent": out.agent = value; idx += 2
            case "--event": out.event = value; idx += 2
            case "--session": out.session = value; idx += 2
            case "--project": out.project = value; idx += 2
            case "--task": out.task = value; idx += 2
            default: idx += 1
            }
        }
        return out
    }

    private static func printUsage() {
        print("""
        trellis-card-hook — Trellis HUD native hook CLI

        Usage:
          trellis-card-hook hook [--agent <name>] [--event <name>] [--session <id>] [--project <dir>] [--task <dir>]
          trellis-card-hook install-hooks [--agent <claude|codex|cursor|pi|opencode|dsh|antigravity|all>] [--uninstall]
          trellis-card-hook status [--json]
        """)
    }
}

exit(TrellisHookCLI.run(args: Array(CommandLine.arguments.dropFirst())))
