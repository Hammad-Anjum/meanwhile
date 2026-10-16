import Foundation
import Testing

/// Pins the hook payload fields Meanwhile relies on, using sessions recorded from real
/// agents (task 0.3). When an agent release changes its format, these fail first.
/// Regenerate fixtures with scripts/extract_fixture.py.
private typealias JSON = [String: Any]

private func fixture(_ name: String) throws -> [JSON] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "ndjson", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? JSON) }
}

private func payloads(_ events: [JSON], event: String, tool: String? = nil) -> [JSON] {
    events.compactMap { $0["payload"] as? JSON }
        .filter { $0["hook_event_name"] as? String == event && (tool == nil || $0["tool_name"] as? String == tool) }
}

@Test(arguments: ["claude-read-websearch-edit-permission", "codex-websearch-patch", "codex-second-run"])
func everyEventHasTheEnvelopeAndSessionFields(name: String) throws {
    for event in try fixture(name) {
        #expect(event["v"] as? Int == 1)
        let payload = try #require(event["payload"] as? JSON)
        #expect(payload["hook_event_name"] as? String == event["event"] as? String)
        for key in ["session_id", "transcript_path", "cwd"] {
            #expect(payload[key] is String, "\(name): \(event["event"] ?? "?") is missing \(key)")
        }
    }
}

@Test func claudeCodeFormats() throws {
    let events = try fixture("claude-read-websearch-edit-permission")

    let prompt = try #require(payloads(events, event: "UserPromptSubmit").first)
    #expect(prompt["prompt"] is String)

    // Needs-input signal: arrives as soon as Claude Code asks, before the Notification.
    let permission = try #require(payloads(events, event: "PermissionRequest").first)
    #expect(permission["tool_name"] is String)

    // Web search: links grouped under `content`, plus the search's text summary.
    let search = try #require(payloads(events, event: "PostToolUse", tool: "WebSearch").first)
    #expect((search["tool_input"] as? JSON)?["query"] is String)
    let results = try #require((search["tool_response"] as? JSON)?["results"] as? [Any])
    let linkGroups = results.compactMap { ($0 as? JSON)?["content"] as? [JSON] }
    let links = try #require(linkGroups.first)
    #expect(links.first?["url"] is String && links.first?["title"] is String)
    #expect(results.contains { $0 is String })

    // Edit: the old and new text, plus a structured diff with line numbers.
    let edit = try #require(payloads(events, event: "PostToolUse", tool: "Edit").first)
    let input = try #require(edit["tool_input"] as? JSON)
    #expect(input["file_path"] is String && input["old_string"] is String && input["new_string"] is String)
    let hunks = try #require((edit["tool_response"] as? JSON)?["structuredPatch"] as? [JSON])
    #expect(hunks.first?["oldStart"] is Int && hunks.first?["lines"] is [String])

    let stop = try #require(payloads(events, event: "Stop").first)
    #expect(stop["last_assistant_message"] is String)
}

@Test(arguments: ["codex-websearch-patch", "codex-second-run"])
func codexFormats(name: String) throws {
    let events = try fixture(name)

    #expect(payloads(events, event: "UserPromptSubmit").first?["prompt"] is String)

    // Web: Codex sends web search and page opens through the `webrun` tool.
    let web = payloads(events, event: "PostToolUse", tool: "webrun")
    #expect(!web.isEmpty)
    for call in web {
        let input = try #require(call["tool_input"] as? JSON)
        #expect(input["search_query"] is [JSON] || input["open"] is [JSON])
        let output = try #require(call["tool_response"] as? [JSON])
        #expect(output.first?["text"] is String)
    }

    // Edits arrive as one patch in apply_patch's `command`.
    let patch = try #require(payloads(events, event: "PostToolUse", tool: "apply_patch").first)
    let command = try #require((patch["tool_input"] as? JSON)?["command"] as? String)
    #expect(command.hasPrefix("*** Begin Patch"))
    #expect(patch["turn_id"] is String)

    let stop = try #require(payloads(events, event: "Stop").first)
    #expect(stop.keys.contains("last_assistant_message"))
}
