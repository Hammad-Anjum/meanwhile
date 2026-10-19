import Foundation

/// Claude Code hook payloads → shared events. Field shapes are pinned by
/// FixtureFormatTests and documented in docs/integrations.md.
enum ClaudeAdapter {
    /// `Notification` types that mean Claude Code is waiting for the user.
    static let needsInputTypes: Set<String> = ["permission_prompt", "idle_prompt"]

    static func events(_ hook: HookEnvelope) -> [AgentEvent] {
        kinds(hook).compactMap { hook.event(.claude, $0) }
    }

    private static func kinds(_ hook: HookEnvelope) -> [AgentEvent.Kind] {
        switch hook.event {
        case "SessionStart":
            return [.sessionStart(source: hook.string("source"))]
        case "UserPromptSubmit":
            return [.turnStart(prompt: hook.string("prompt") ?? "")]
        case "PostToolUse":
            return tool(hook, failed: false)
        case "PostToolUseFailure":
            return tool(hook, failed: true)
        case "PermissionRequest":
            return [.permissionRequest(tool: hook.toolName, detail: permissionDetail(hook.toolInput))]
        case "Notification":
            let type = hook.string("notification_type")
            if let type, needsInputTypes.contains(type) { return [.needsInput(reason: type)] }
            return [.notification(type: type, message: hook.string("message"))]
        case "Stop":
            return [.turnEnd(lastMessage: hook.string("last_assistant_message"), outcome: .completed)]
        case "StopFailure":
            return [.turnEnd(lastMessage: hook.string("last_assistant_message"), outcome: .failed)]
        case "SubagentStop":
            return [.subagentEnd(lastMessage: hook.string("last_assistant_message"))]
        case "SessionEnd":
            return [.sessionEnd(reason: hook.string("reason"))]
        default:
            return []
        }
    }

    private static func tool(_ hook: HookEnvelope, failed: Bool) -> [AgentEvent.Kind] {
        let input = hook.toolInput
        let response = hook.toolResponse as? [String: Any] ?? [:]
        let name = hook.toolName

        switch name {
        case "Bash":
            let command = input["command"] as? String ?? ""
            let output = failed
                ? hook.string("error")
                : [response["stdout"], response["stderr"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
                    .joined(separator: "\n")
            let reads = failed ? [] : ShellCommand.readPaths(in: command, cwd: hook.cwd).map { AgentEvent.Kind.read(path: $0) }
            return [.exec(command: command, output: Caps.text(output, Caps.outputCharacters), failed: failed)] + reads
        case _ where failed:
            return [.tool(name: name)]
        case "Read":
            guard let path = input["file_path"] as? String else { return [.tool(name: name)] }
            return [.read(path: path)]
        case "Edit", "MultiEdit", "Write":
            guard let edit = fileEdit(name, input, response) else { return [.tool(name: name)] }
            return [.edit([edit])]
        case "WebSearch":
            var activity = WebActivity(queries: [input["query"] as? String].compactMap { $0 })
            for result in response["results"] as? [Any] ?? [] {
                if let summary = result as? String {
                    activity.text = [activity.text, summary].compactMap { $0 }.joined(separator: "\n\n")
                } else if let group = (result as? [String: Any])?["content"] as? [[String: Any]] {
                    activity.links += group.compactMap { link in
                        guard let url = link["url"] as? String else { return nil }
                        return WebActivity.Link(title: link["title"] as? String ?? url, url: url)
                    }
                }
            }
            activity.text = Caps.text(activity.text, Caps.webTextCharacters)
            return [.web(activity)]
        case "WebFetch":
            return [.web(WebActivity(
                urls: [input["url"] as? String].compactMap { $0 },
                text: Caps.text(response["result"] as? String, Caps.webTextCharacters)
            ))]
        default:
            return [.tool(name: name)]
        }
    }

    /// Prefers the structured diff Claude Code returns; falls back to the tool's input.
    private static func fileEdit(_ tool: String, _ input: [String: Any], _ response: [String: Any]) -> FileEdit? {
        guard let path = input["file_path"] as? String else { return nil }
        let isNew = tool == "Write" && (response["originalFile"] == nil || response["originalFile"] is NSNull)
        var edit = FileEdit(path: path, change: isNew ? .added : .modified)

        if let hunks = response["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
            for line in hunks.flatMap({ $0["lines"] as? [String] ?? [] }) {
                if line.hasPrefix("+") { edit.added.append(String(line.dropFirst())) }
                else if line.hasPrefix("-") { edit.removed.append(String(line.dropFirst())) }
            }
        } else if tool == "Write" {
            edit.added = (input["content"] as? String ?? "").lines
        } else {
            let pairs = (input["edits"] as? [[String: Any]]) ?? [input]
            for pair in pairs {
                edit.removed += (pair["old_string"] as? String ?? "").lines
                edit.added += (pair["new_string"] as? String ?? "").lines
            }
        }
        edit.added = Caps.lines(edit.added)
        edit.removed = Caps.lines(edit.removed)
        return edit
    }

    static func permissionDetail(_ input: [String: Any]) -> String? {
        ["command", "file_path", "url", "query"].lazy.compactMap { input[$0] as? String }.first
    }
}
