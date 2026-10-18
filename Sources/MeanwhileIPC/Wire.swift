import Foundation

/// The message `meanwhile-hook` sends to the app: one line of JSON per hook event.
///
///     {"v":1,"agent":"claude","event":"PostToolUse","ts":"…","ppid":123,
///      "term":{"TERM_PROGRAM":"iTerm.app"},"payload":{…the agent's own JSON…}}
///
/// The agent's payload is passed through untouched; adapters in MeanwhileCore parse it.
public enum Wire {
    public static let version = 1
    /// Must match the event server's default line limit. This excludes the final newline.
    public static let maximumLineBytes = 16 * 1024 * 1024

    /// Set on Meanwhile's own `claude -p` / `codex exec` calls so their hooks are ignored.
    public static let internalCallVariable = "MEANWHILE_INTERNAL"

    /// Environment variables kept so the app can find the agent's terminal or editor later.
    static let terminalVariables = ["TERM_PROGRAM", "TERM_SESSION_ID", "ITERM_SESSION_ID", "__CFBundleIdentifier"]

    public static func envelope(
        agent: String,
        event: String,
        payload: Data,
        environment: [String: String],
        parentPID: Int32,
        date: Date = Date(),
        payloadWasTruncated: Bool = false
    ) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var object: [String: Any] = [
            "v": version,
            "agent": agent,
            "event": event,
            "ts": formatter.string(from: date),
            "ppid": Int(parentPID),
            "term": environment.filter { terminalVariables.contains($0.key) },
        ]
        if payloadWasTruncated {
            object["payloadTruncated"] = true
            object["payloadBytesAtLeast"] = payload.count
        } else if let json = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]) {
            object["payload"] = json
        } else {
            object["payloadRaw"] = String(decoding: payload, as: UTF8.self)
        }

        var line = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        if line.count > maximumLineBytes {
            object.removeValue(forKey: "payload")
            object.removeValue(forKey: "payloadRaw")
            object["payloadTruncated"] = true
            object["payloadBytesAtLeast"] = payload.count
            line = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        }
        line.append(0x0A)
        return line
    }
}
