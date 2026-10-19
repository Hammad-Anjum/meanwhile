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
    let retainedBytes: Int
}

/// Task 0.2 debug log: receives raw hook events, keeps them for the Event Log window,
/// and appends them to the debug recording used for fixtures.
@MainActor @Observable
final class EventLog {
    private static let maximumVisibleEvents = 2_000
    private static let maximumVisibleBytes = 32 * 1024 * 1024
    private static let maximumRecordingBytes: UInt64 = 32 * 1024 * 1024

    private(set) var events: [DebugEvent] = []
    private(set) var serverError: String?
    private(set) var storeError: String?
    /// Called with the shared events adapted from each live hook line. Not called for
    /// spooled lines drained at launch: those turns are already over.
    @ObservationIgnored var onEvents: (([AgentEvent]) -> Void)?
    @ObservationIgnored private var server: EventServer?
    @ObservationIgnored private let store: EventStore?
    @ObservationIgnored private var retainedEventBytes = 0

    /// Lines are saved to `store` on the server's background queue before the UI sees them.
    init(store: EventStore?, storeError: String? = nil) {
        self.storeError = storeError
        self.store = store
        let server = EventServer { [weak self] line in
            let events = (try? store?.ingest(line)) ?? EventAdapter.events(fromLine: line)
            Task { @MainActor in
                self?.ingest(line)
                if !events.isEmpty { self?.onEvents?(events) }
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            serverError = "Could not listen on \(MeanwhilePaths.socket.path): \(error)"
        }
        drainSpool(live: false)
    }

    /// Takes in lines the hook spooled. At launch they belong to turns that are over, so they
    /// only go to the store and the log; while running they are recent and reach `onEvents` too.
    func drainSpool(live: Bool = true) {
        for line in Spool.drain() {
            let events = (try? store?.ingest(line)) ?? EventAdapter.events(fromLine: line)
            ingest(line)
            if live, !events.isEmpty { onEvents?(events) }
        }
    }

    /// Stop accepting hook connections and remove the socket before the app exits.
    /// `EventServer.start()` can recover from a stale socket, but an orderly shutdown
    /// avoids leaving one behind in the common case.
    func stop() {
        server?.stop()
        server = nil
    }

    func clear() {
        events.removeAll()
        retainedEventBytes = 0
    }

    private func ingest(_ line: Data) {
        record(line)
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let pretty = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let payload = object["payload"] as? [String: Any] ?? [:]
        let event = payload["hook_event_name"] as? String ?? object["event"] as? String ?? "?"
        let summary = Self.summary(of: payload)
        let retainedBytes = pretty.utf8.count + summary.utf8.count
        events.append(DebugEvent(
            receivedAt: Date(),
            agent: object["agent"] as? String ?? "?",
            event: event,
            summary: summary,
            prettyJSON: pretty,
            retainedBytes: retainedBytes
        ))
        retainedEventBytes += retainedBytes
        trimVisibleEvents()
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
        if let message = payload["last_assistant_message"] as? String {
            return message.count > 80 ? String(message.prefix(80)) + "…" : message
        }
        if let type = payload["notification_type"] as? String { return type }
        return ""
    }

    private func record(_ line: Data) {
        let url = MeanwhilePaths.debugRecording
        let directory = url.deletingLastPathComponent()
        let previous = directory.appendingPathComponent("events.previous.ndjson")
        var framedLine = line
        if framedLine.last != 0x0A { framedLine.append(0x0A) }
        guard framedLine.count <= Self.maximumRecordingBytes else { return }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let previousBytes = ((try? FileManager.default.attributesOfItem(atPath: previous.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        if previousBytes > Self.maximumRecordingBytes {
            do { try FileManager.default.removeItem(at: previous) } catch { return }
        }

        var existingBytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        if existingBytes > Self.maximumRecordingBytes {
            // A recording created by an older build may already be over the new
            // bound. It is debug-only data, so discard it instead of retaining an
            // indefinitely large file during the first rotation.
            do { try FileManager.default.removeItem(at: url) } catch { return }
            existingBytes = 0
        }
        if existingBytes + UInt64(framedLine.count) > Self.maximumRecordingBytes {
            try? FileManager.default.removeItem(at: previous)
            do {
                try FileManager.default.moveItem(at: url, to: previous)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.path)
            } catch CocoaError.fileNoSuchFile {
                // There was no current recording to rotate.
            } catch {
                return // Never grow an existing recording past the configured bound.
            }
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        // The recording can contain prompts, paths, and tool arguments. Repair
        // permissions too, rather than only protecting newly-created files.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(framedLine)
    }

    private func trimVisibleEvents() {
        var removeCount = 0
        while removeCount < events.count,
              events.count - removeCount > Self.maximumVisibleEvents
                || retainedEventBytes > Self.maximumVisibleBytes {
            retainedEventBytes -= events[removeCount].retainedBytes
            removeCount += 1
        }
        if removeCount > 0 { events.removeFirst(removeCount) }
    }
}
