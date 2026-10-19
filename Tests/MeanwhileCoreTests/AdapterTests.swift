import Foundation
import Testing
import MeanwhileIPC
@testable import MeanwhileCore

/// Task 1.1: the Claude Code and Codex adapters, run over the 0.3 recordings.

private func fixtureEvents(_ name: String) throws -> [AgentEvent] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "ndjson", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .flatMap { EventAdapter.events(fromLine: Data($0.utf8)) }
}

/// A hook line as `meanwhile-hook` would send it.
private func line(_ agent: String, _ payload: [String: Any]) throws -> Data {
    var payload = payload
    payload["session_id"] = payload["session_id"] ?? "s1"
    payload["cwd"] = payload["cwd"] ?? "/repo"
    let json = try JSONSerialization.data(withJSONObject: payload)
    return Wire.envelope(agent: agent, event: payload["hook_event_name"] as? String ?? "?",
                         payload: json, environment: ["TERM_PROGRAM": "iTerm.app"], parentPID: 42)
}

private func kinds(_ events: [AgentEvent]) -> [String] { events.map(\.kind.name) }

@Test func claudeRecordingMapsToSharedEvents() throws {
    let events = try fixtureEvents("claude-read-websearch-edit-permission")
    let names = kinds(events)

    #expect(names.first == "session.start")
    #expect(names.contains("turn.start"))
    // Claude Code sends an idle_prompt Notification after Stop, once the session sits idle.
    #expect(Array(names.suffix(2)) == ["turn.end", "needs.input"])
    #expect(Set(events.map(\.session)).count == 1)
    #expect(events.allSatisfy { $0.agent == .claude && !$0.cwd.isEmpty })

    // Auto mode sends PermissionRequest; only the permission_prompt Notification means waiting.
    #expect(names.contains("permission.request"))
    #expect(events.contains { if case .needsInput("permission_prompt") = $0.kind { true } else { false } })

    let web = try #require(events.lazy.compactMap { if case .web(let w) = $0.kind { w } else { nil } }.first)
    #expect(!web.queries.isEmpty && !web.links.isEmpty && web.text != nil)

    let edits = events.compactMap { if case .edit(let e) = $0.kind { e } else { nil } }.flatMap { $0 }
    let edit = try #require(edits.first)
    #expect(edit.change == .modified && !edit.added.isEmpty && edit.path.hasPrefix("/"))

    // In this session Claude read files with cat/sed through Bash.
    #expect(names.contains("tool.exec"))
    #expect(names.contains("tool.read"))

    if case .turnEnd(let message, .completed) = try #require(events.last { $0.kind.name == "turn.end" }).kind {
        #expect(message?.isEmpty == false)
    } else {
        Issue.record("last event is not a completed turn end")
    }
}

@Test(arguments: ["codex-websearch-patch", "codex-second-run"])
func codexRecordingMapsToSharedEvents(name: String) throws {
    let events = try fixtureEvents(name)
    let names = kinds(events)

    #expect(names.contains("session.start") && names.contains("turn.start") && names.last == "turn.end")
    #expect(events.allSatisfy { $0.agent == .codex })
    #expect(events.filter { $0.kind.name.hasPrefix("tool.") }.allSatisfy { $0.turn != nil })

    let web = events.compactMap { if case .web(let w) = $0.kind { w } else { nil } }
    #expect(web.contains { !$0.queries.isEmpty })
    #expect(web.contains { !$0.urls.isEmpty })
    #expect(web.contains { !$0.links.isEmpty })

    let edits = events.compactMap { if case .edit(let e) = $0.kind { e } else { nil } }.flatMap { $0 }
    #expect(!edits.isEmpty && edits.allSatisfy { $0.path.hasPrefix("/") })
}

@Test func codexRecordingSeesTheAddedFile() throws {
    let events = try fixtureEvents("codex-websearch-patch")
    let edit = try #require(events.compactMap { if case .edit(let e) = $0.kind { e.first } else { nil } }.first)
    #expect(edit.path.hasSuffix("docs/TRY.md") && edit.change == .added)
    #expect(edit.added.first?.contains("DynamicNotchKit") == true)
}

@Test func notificationsOnlyCountAsNeedsInputWhenWaiting() throws {
    for (type, expected) in [("permission_prompt", "needs.input"), ("idle_prompt", "needs.input"),
                             ("agent_completed", "notification")] {
        let events = EventAdapter.events(fromLine: try line("claude", [
            "hook_event_name": "Notification", "notification_type": type, "message": "m",
        ]))
        #expect(kinds(events) == [expected], "\(type)")
    }
}

@Test func envelopeFieldsCarryOver() throws {
    let event = try #require(EventAdapter.events(fromLine: try line("codex", [
        "hook_event_name": "UserPromptSubmit", "prompt": "hi", "turn_id": "t1",
        "transcript_path": "/tmp/t.jsonl", "agent_id": "sub",
    ])).first)
    #expect(event.kind == .turnStart(prompt: "hi"))
    #expect(event.turn == "t1" && event.subagent == "sub" && event.transcript == "/tmp/t.jsonl")
    #expect(event.terminal.program == "iTerm.app" && event.terminal.parentPID == 42)

    let decoded = try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(event))
    #expect(decoded == event)
}

@Test func failedClaudeCommandKeepsTheError() throws {
    let events = EventAdapter.events(fromLine: try line("claude", [
        "hook_event_name": "PostToolUseFailure", "tool_name": "Bash",
        "tool_input": ["command": "cat missing.txt"], "error": "No such file",
    ]))
    #expect(events.map(\.kind) == [.exec(command: "cat missing.txt", output: "No such file", failed: true)])
}

@Test func codexExitCodeMarksFailure() throws {
    let events = EventAdapter.events(fromLine: try line("codex", [
        "hook_event_name": "PostToolUse", "tool_name": "Bash",
        "tool_input": ["command": "swift test"], "tool_response": "Exit code: 1\nOutput:\nfailed",
    ]))
    if case .exec(_, _, let failed) = try #require(events.first).kind { #expect(failed) }
}

@Test func linesThatAreNotEventsAreIgnored() throws {
    #expect(EventAdapter.events(fromLine: Data("not json".utf8)).isEmpty)
    #expect(EventAdapter.events(fromLine: try line("cursor", ["hook_event_name": "stop"])).isEmpty)
    #expect(EventAdapter.events(fromLine: try line("claude", ["hook_event_name": "SomethingNew"])).isEmpty)
    // No session id: can't be attributed, so dropped.
    let anonymous = Wire.envelope(agent: "claude", event: "Stop", payload: Data(#"{"hook_event_name":"Stop"}"#.utf8),
                                  environment: [:], parentPID: 1)
    #expect(EventAdapter.events(fromLine: anonymous).isEmpty)
}

@Test(arguments: [
    ("cat README.md && cat Package.resolved", ["/repo/README.md", "/repo/Package.resolved"]),
    ("sed -n '1,80p' docs/mvp-plan.md | head -5", ["/repo/docs/mvp-plan.md"]),
    ("cd docs && cat a.md; nl -ba ../b.swift", ["/repo/docs/a.md", "/repo/b.swift"]),
    ("bash -lc \"head -n 20 'My File.txt'\"", ["/repo/My File.txt"]),
    ("LC_ALL=C tail -40 /var/log/x.log 2>/dev/null", ["/var/log/x.log"]),
    ("grep -n foo src/a.swift", []),
    ("sed 's/a/b/' in.txt > out.txt", []),
    ("echo hi > notes.md", []),
])
func shellReadDetection(command: String, expected: [String]) {
    #expect(ShellCommand.readPaths(in: command, cwd: "/repo") == expected)
}

@Test func applyPatchSplitsPerFile() {
    let patch = """
    *** Begin Patch
    *** Update File: Sources/A.swift
    @@ func a()
     let keep = 1
    -let old = 2
    +let new = 3
    *** Update File: B.md
    *** Move to: docs/B.md
    +moved
    *** Delete File: /abs/C.txt
    *** End Patch
    """
    let edits = ApplyPatch.edits(in: patch, cwd: "/repo")
    #expect(edits == [
        FileEdit(path: "/repo/Sources/A.swift", change: .modified, added: ["let new = 3"], removed: ["let old = 2"]),
        FileEdit(path: "/repo/B.md", change: .modified, added: ["moved"], movedTo: "/repo/docs/B.md"),
        FileEdit(path: "/abs/C.txt", change: .deleted),
    ])
}
