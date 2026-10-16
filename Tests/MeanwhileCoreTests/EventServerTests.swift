import Foundation
import Testing
@testable import MeanwhileCore
import MeanwhileIPC

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []
    func add(_ line: Data) { lock.withLock { lines.append(line) } }
    var all: [Data] { lock.withLock { lines } }
}

private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

private func shortSocketPath() -> String {
    // sockaddr_un caps paths at 104 bytes, so keep test sockets in /tmp.
    "/tmp/mw-test-\(UUID().uuidString.prefix(8)).sock"
}

@Test func serverReceivesWhatTheHookSends() async throws {
    let path = shortSocketPath()
    let received = Received()
    let server = EventServer(path: path) { received.add($0) }
    try server.start()
    defer { server.stop() }

    let line = Wire.envelope(agent: "claude", event: "Stop", payload: Data(#"{"session_id":"abc"}"#.utf8),
                             environment: ["TERM_PROGRAM": "iTerm.app", "SECRET": "x"], parentPID: 42)
    #expect(UnixSocket.send(line, to: path))

    await waitFor { received.all.count == 1 }
    let first = try #require(received.all.first)
    let object = try #require(try JSONSerialization.jsonObject(with: first) as? [String: Any])
    #expect(object["agent"] as? String == "claude")
    #expect(object["event"] as? String == "Stop")
    #expect((object["payload"] as? [String: Any])?["session_id"] as? String == "abc")
    #expect((object["term"] as? [String: String]) == ["TERM_PROGRAM": "iTerm.app"]) // other env vars dropped
}

@Test func largePayloadArrivesWhole() async throws {
    let path = shortSocketPath()
    let received = Received()
    let server = EventServer(path: path) { received.add($0) }
    try server.start()
    defer { server.stop() }

    let big = String(repeating: "x", count: 500_000)
    let line = Wire.envelope(agent: "claude", event: "PostToolUse",
                             payload: Data(#"{"tool_response":"\#(big)"}"#.utf8), environment: [:], parentPID: 1)
    #expect(UnixSocket.send(line, to: path))

    await waitFor { received.all.count == 1 }
    #expect(received.all.first?.count == line.count - 1) // minus the newline
}

@Test func sendFailsWhenNothingListens() {
    #expect(!UnixSocket.send(Data("hi\n".utf8), to: shortSocketPath()))
}

@Test func nonJSONPayloadIsKeptAsRawText() throws {
    let line = Wire.envelope(agent: "codex", event: "Stop", payload: Data("not json".utf8), environment: [:], parentPID: 1)
    let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    #expect(object["payloadRaw"] as? String == "not json")
}

@Test func spoolKeepsOrderAndEmpties() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mw-spool-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    Spool.append(Data("one\n".utf8), in: directory)
    Spool.append(Data("two\n".utf8), in: directory)
    #expect(Spool.drain(in: directory).map { String(decoding: $0, as: UTF8.self) } == ["one", "two"])
    #expect(Spool.drain(in: directory).isEmpty)
}
