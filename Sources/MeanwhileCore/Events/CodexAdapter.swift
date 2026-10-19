import Foundation

/// Codex hook payloads → shared events. Codex has no `Notification` hook, so it never
/// produces `needsInput`; the session tracker infers waiting from timing instead.
enum CodexAdapter {
    private static let shellTools: Set<String> = ["Bash", "shell", "exec_command", "local_shell"]

    static func events(_ hook: HookEnvelope) -> [AgentEvent] {
        kinds(hook).compactMap { hook.event(.codex, $0) }
    }

    private static func kinds(_ hook: HookEnvelope) -> [AgentEvent.Kind] {
        switch hook.event {
        case "SessionStart":
            return [.sessionStart(source: hook.string("source"))]
        case "UserPromptSubmit":
            return [.turnStart(prompt: hook.string("prompt") ?? "")]
        case "PostToolUse":
            return tool(hook)
        case "PermissionRequest":
            return [.permissionRequest(tool: hook.toolName, detail: ClaudeAdapter.permissionDetail(hook.toolInput))]
        case "Stop":
            return [.turnEnd(lastMessage: hook.string("last_assistant_message"), outcome: .completed)]
        case "Interrupt":
            return [.turnEnd(lastMessage: nil, outcome: .interrupted)]
        case "SubagentStop":
            return [.subagentEnd(lastMessage: hook.string("last_assistant_message"))]
        case "SessionEnd":
            return [.sessionEnd(reason: hook.string("reason"))]
        default:
            return []
        }
    }

    private static func tool(_ hook: HookEnvelope) -> [AgentEvent.Kind] {
        let input = hook.toolInput
        let name = hook.toolName
        let output = hook.toolResponse as? String

        if shellTools.contains(name) {
            // `command` is a string from the Bash tool, an argv array from older shell tools.
            let command = input["command"] as? String
                ?? (input["command"] as? [String])?.joined(separator: " ") ?? ""
            let reads = ShellCommand.readPaths(in: command, cwd: hook.cwd).map { AgentEvent.Kind.read(path: $0) }
            return [.exec(command: command, output: Caps.text(output, Caps.outputCharacters),
                          failed: exitCode(output).map { $0 != 0 } ?? false)] + reads
        }
        switch name {
        case "apply_patch":
            let edits = ApplyPatch.edits(in: input["command"] as? String ?? "", cwd: hook.cwd)
            return edits.isEmpty ? [.tool(name: name)] : [.edit(edits)]
        case "webrun":
            let texts = (hook.toolResponse as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            let text = texts.joined(separator: "\n\n")
            return [.web(WebActivity(
                queries: (input["search_query"] as? [[String: Any]] ?? []).compactMap { $0["q"] as? String },
                urls: (input["open"] as? [[String: Any]] ?? []).compactMap { $0["ref_id"] as? String }
                    .filter { $0.hasPrefix("http") },
                links: links(in: text),
                text: Caps.text(text.isEmpty ? nil : text, Caps.webTextCharacters)
            ))]
        default:
            return [.tool(name: name)]
        }
    }

    /// Codex reports `Exit code: N` at the top of some tool outputs.
    private static func exitCode(_ output: String?) -> Int? {
        guard let first = output?.lines.first, first.hasPrefix("Exit code: ") else { return nil }
        return Int(first.dropFirst("Exit code: ".count))
    }

    /// webrun results put each source on a line as `Title (https://…)`.
    private static func links(in text: String) -> [WebActivity.Link] {
        let pattern = /^(.+?) \((https?:\/\/[^\s)]+)\)\s*$/
        var seen = Set<String>()
        return text.lines.compactMap { line in
            guard let match = line.wholeMatch(of: pattern), seen.insert(String(match.2)).inserted else { return nil }
            return WebActivity.Link(title: String(match.1), url: String(match.2))
        }
    }
}
