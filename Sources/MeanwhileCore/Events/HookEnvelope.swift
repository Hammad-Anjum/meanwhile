import Foundation
import MeanwhileIPC

/// One line from `meanwhile-hook`, decoded (see `Wire.envelope`). The payload is the
/// agent's own JSON, left as a dictionary for the adapters.
struct HookEnvelope {
    let agent: String
    let event: String
    let timestamp: Date
    let terminal: Terminal
    let payload: [String: Any]

    /// Nil for lines that aren't envelopes, or whose payload was truncated or isn't an object.
    init?(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["v"] as? Int == Wire.version,
              let agent = object["agent"] as? String,
              let payload = object["payload"] as? [String: Any]
        else { return nil }

        self.agent = agent
        self.event = payload["hook_event_name"] as? String ?? object["event"] as? String ?? ""
        self.timestamp = (object["ts"] as? String).flatMap(Self.parseDate) ?? Date()
        let term = object["term"] as? [String: String] ?? [:]
        self.terminal = Terminal(
            program: term["TERM_PROGRAM"],
            sessionID: term["ITERM_SESSION_ID"] ?? term["TERM_SESSION_ID"],
            bundleID: term["__CFBundleIdentifier"],
            parentPID: object["ppid"] as? Int
        )
        self.payload = payload
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// An event carrying the fields every hook payload has. Nil if the payload
    /// lacks a session or working directory.
    func event(_ agent: AgentEvent.Agent, _ kind: AgentEvent.Kind) -> AgentEvent? {
        guard let session = string("session_id"), let cwd = string("cwd") else { return nil }
        return AgentEvent(
            agent: agent,
            session: session,
            turn: string("turn_id") ?? string("prompt_id"),
            subagent: string("agent_id"),
            timestamp: timestamp,
            cwd: cwd,
            transcript: string("transcript_path"),
            terminal: terminal,
            kind: kind
        )
    }

    func string(_ key: String) -> String? { payload[key] as? String }
    var cwd: String { string("cwd") ?? "" }
    var toolName: String { string("tool_name") ?? "" }
    var toolInput: [String: Any] { payload["tool_input"] as? [String: Any] ?? [:] }
    var toolResponse: Any? { payload["tool_response"] }
}

/// Turns hook lines into shared events. One line can become several events
/// (a shell command that also read files), or none (an event Meanwhile doesn't use).
public enum EventAdapter {
    public static func events(fromLine line: Data) -> [AgentEvent] {
        guard let envelope = HookEnvelope(line: line) else { return [] }
        switch envelope.agent {
        case "claude": return ClaudeAdapter.events(envelope)
        case "codex": return CodexAdapter.events(envelope)
        default: return []
        }
    }
}

/// Limits that keep one event small. The raw line is kept separately by the store.
enum Caps {
    static let outputCharacters = 4_000
    static let webTextCharacters = 20_000
    static let editLines = 2_000

    static func text(_ value: String?, _ limit: Int) -> String? {
        guard let value else { return nil }
        return value.count > limit ? String(value.prefix(limit)) : value
    }

    static func lines(_ value: [String]) -> [String] {
        value.count > editLines ? Array(value.prefix(editLines)) : value
    }
}

extension String {
    /// Lines without their terminators; empty for an empty string.
    var lines: [String] {
        isEmpty ? [] : split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
