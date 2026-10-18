import Foundation
import Observation
import MeanwhileCore
import MeanwhileIPC

/// One received hook event, as shown in the debug window.
struct DebugEvent: Identifiable {
    let id = UUID()
    let receivedAt: Date
    let agent: String
    let event: String
    let summary: String
    let prettyJSON: String
}

/// Task 0.2 debug log: receives raw hook events, keeps them for the Event Log window,
/// and appends them to the debug recording used for fixtures.
@MainActor @Observable
final class EventLog {
    private(set) var events: [DebugEvent] = []
    private(set) var serverError: String?
    /// Called with each event's hook name (e.g. `UserPromptSubmit`). Drives the notch spike.
    @ObservationIgnored var onAgentEvent: ((String) -> Void)?
    @ObservationIgnored private var server: EventServer?

    init() {
        let server = EventServer { [weak self] line in
            Task { @MainActor in self?.ingest(line) }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            serverError = "Could not listen on \(MeanwhilePaths.socket.path): \(error)"
        }
        for line in Spool.drain() { ingest(line) }
    }

    func clear() { events.removeAll() }

    private func ingest(_ line: Data) {
        record(line)
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let pretty = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let payload = object["payload"] as? [String: Any] ?? [:]
        let event = payload["hook_event_name"] as? String ?? object["event"] as? String ?? "?"
        onAgentEvent?(event)
        events.append(DebugEvent(
            receivedAt: Date(),
            agent: object["agent"] as? String ?? "?",
            event: event,
            summary: Self.summary(of: payload),
            prettyJSON: pretty
        ))
    }

    /// A one-line hint per event: the tool and its main argument, or the prompt.
    private static func summary(of payload: [String: Any]) -> String {
        if let prompt = payload["prompt"] as? String { return "“\(prompt.prefix(80))”" }
        if let tool = payload["tool_name"] as? String {
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let detail = ["file_path", "command", "query", "url", "pattern", "description"]
                .lazy.compactMap { input[$0] as? String }.first ?? ""
            return detail.isEmpty ? tool : "\(tool) · \(detail.prefix(80))"
        }
        if let message = payload["last_assistant_message"] as? String { return message.prefix(80) + "…" }
        if let type = payload["notification_type"] as? String { return type }
        return ""
    }

    private func record(_ line: Data) {
        let url = MeanwhilePaths.debugRecording
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(line + Data([0x0A]))
    }
}
