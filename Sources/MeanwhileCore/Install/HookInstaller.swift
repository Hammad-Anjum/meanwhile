import Foundation

/// Adds and removes Meanwhile's hook entries in an agent's user-level hook config
/// (docs/integrations.md, "Where hooks are configured"). Only entries whose command runs
/// `meanwhile-hook` are ever touched; everything else in the file is kept.
public struct HookInstaller: Sendable {
    public enum Agent: String, Sendable, CaseIterable {
        case claude, codex

        public var displayName: String { self == .claude ? "Claude Code" : "Codex" }

        /// The config file, relative to the home directory.
        var configPath: String { self == .claude ? ".claude/settings.json" : ".codex/hooks.json" }

        /// The agent's own directory; its presence means the agent is installed.
        var homeDirectory: String { self == .claude ? ".claude" : ".codex" }

        /// Hook events Meanwhile listens to, and whether each takes a tool `matcher`.
        var events: [(name: String, toolMatcher: Bool)] {
            switch self {
            case .claude:
                [("SessionStart", false), ("SessionEnd", false), ("UserPromptSubmit", false),
                 ("PostToolUse", true), ("PostToolUseFailure", true), ("Notification", false),
                 ("PermissionRequest", false), ("SubagentStop", false), ("Stop", false), ("StopFailure", false)]
            case .codex:
                [("SessionStart", false), ("SessionEnd", false), ("UserPromptSubmit", false),
                 ("PostToolUse", true), ("PermissionRequest", false), ("SubagentStop", false), ("Stop", false)]
            }
        }
    }

    /// What installing or uninstalling would do to one config file.
    public struct Plan: Sendable, Equatable {
        public let agent: Agent
        public let file: URL
        public let before: String?
        public let after: String
        public let added: [String]
        public let removed: [String]

        /// A missing file and an empty result count as the same: nothing to write.
        public var changes: Bool { after != (before ?? "") }
    }

    public static let marker = "meanwhile-hook"

    public let home: URL
    /// Absolute path of the installed `meanwhile-hook` the entries will run.
    public let hookPath: String

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, hookPath: String) {
        self.home = home
        self.hookPath = hookPath
    }

    /// Agents whose directory exists in the home folder.
    public func detectedAgents() -> [Agent] {
        Agent.allCases.filter {
            FileManager.default.fileExists(atPath: home.appendingPathComponent($0.homeDirectory).path)
        }
    }

    public func file(for agent: Agent) -> URL { home.appendingPathComponent(agent.configPath) }

    /// The config with Meanwhile's entries replaced by a fresh set.
    public func installPlan(for agent: Agent) throws -> Plan {
        let (before, object) = try read(agent)
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        let removed = Self.removeOurs(from: &hooks)
        for event in agent.events {
            var entry: [String: Any] = ["hooks": [[
                "type": "command",
                "async": true,
                "command": "\"\(hookPath)\" \(agent.rawValue) \(event.name)",
            ]]]
            if event.toolMatcher { entry["matcher"] = "*" }
            hooks[event.name] = (hooks[event.name] as? [Any] ?? []) + [entry]
        }
        var updated = object
        updated["hooks"] = hooks
        let added = agent.events.map(\.name).filter { !removed.contains($0) }
        return Plan(agent: agent, file: file(for: agent), before: before, after: try Self.serialize(updated),
                    added: added, removed: removed.filter { name in !agent.events.contains { $0.name == name } })
    }

    /// The config without any of Meanwhile's entries. Event lists and a `hooks` object
    /// that only Meanwhile used are removed too, so the file returns to how it was.
    public func uninstallPlan(for agent: Agent) throws -> Plan {
        let (before, object) = try read(agent)
        var updated = object
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        let removed = Self.removeOurs(from: &hooks)
        if hooks.isEmpty { updated["hooks"] = nil } else { updated["hooks"] = hooks }
        let after = removed.isEmpty ? (before ?? "") : try Self.serialize(updated)
        return Plan(agent: agent, file: file(for: agent), before: before, after: after, added: [], removed: removed)
    }

    /// Writes a plan, keeping a timestamped backup of the previous file next to it.
    /// Returns the backup's URL, if there was a file to back up.
    @discardableResult
    public func apply(_ plan: Plan, now: Date = Date()) throws -> URL? {
        guard plan.changes else { return nil }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: plan.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        if let before = plan.before {
            let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
            let url = plan.file.appendingPathExtension("meanwhile-backup-\(stamp)")
            try Data(before.utf8).write(to: url, options: .atomic)
            backup = url
        }
        try Data(plan.after.utf8).write(to: plan.file, options: .atomic)
        return backup
    }

    // MARK: JSON

    private func read(_ agent: Agent) throws -> (String?, [String: Any]) {
        let url = file(for: agent)
        guard let data = try? Data(contentsOf: url) else { return (nil, [:]) }
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (text, [:]) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.notAnObject(url.path)
        }
        return (text, object)
    }

    /// Removes Meanwhile's entries from every event list; drops lists left empty.
    /// Returns the events that had one.
    private static func removeOurs(from hooks: inout [String: Any]) -> [String] {
        var touched: [String] = []
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !isOurs($0) }
            guard kept.count != entries.count else { continue }
            touched.append(event)
            hooks[event] = kept.isEmpty ? nil : kept
        }
        return touched.sorted()
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    private static func serialize(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

public enum InstallError: Error, CustomStringConvertible {
    case notAnObject(String)
    case missingHookBinary(String)
    case launchctl(String)

    public var description: String {
        switch self {
        case .notAnObject(let path): "\(path) is not a JSON object; left it alone"
        case .missingHookBinary(let path): "meanwhile-hook not found at \(path)"
        case .launchctl(let message): "launchctl: \(message)"
        }
    }
}
