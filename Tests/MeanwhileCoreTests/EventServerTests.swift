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

@Test func separateConnectionsAreDeliveredInAcceptanceOrder() async throws {
    let path = shortSocketPath()
    let received = Received()
    let server = EventServer(path: path) { received.add($0) }
    try server.start()
    defer { server.stop() }

    for index in 0..<100 {
        #expect(UnixSocket.send(Data("event-\(index)\n".utf8), to: path))
    }

    await waitFor { received.all.count == 100 }
    #expect(received.all.map { String(decoding: $0, as: UTF8.self) }
        == (0..<100).map { "event-\($0)" })
}

@Test func sendFailsWhenNothingListens() {
    #expect(!UnixSocket.send(Data("hi\n".utf8), to: shortSocketPath()))
}

@Test func startingTwiceDoesNotOrphanTheOriginalListener() async throws {
    let path = shortSocketPath()
    let received = Received()
    let first = EventServer(path: path) { received.add($0) }
    let second = EventServer(path: path) { _ in }
    try first.start()
    defer { first.stop(); second.stop() }

    var rejectedSecondListener = false
    do {
        try second.start()
    } catch EventServerError.pathOccupied {
        rejectedSecondListener = true
    }
    #expect(rejectedSecondListener)
    #expect(UnixSocket.send(Data("still-alive\n".utf8), to: path))
    await waitFor { received.all.count == 1 }
    #expect(received.all.first == Data("still-alive".utf8))
}

@Test func repeatedStartOnOneServerIsRejectedAndCanRestartAfterStop() throws {
    let path = shortSocketPath()
    let server = EventServer(path: path) { _ in }
    try server.start()

    var rejectedRepeatedStart = false
    do {
        try server.start()
    } catch EventServerError.alreadyRunning {
        rejectedRepeatedStart = true
    }
    #expect(rejectedRepeatedStart)

    server.stop()
    try server.start()
    server.stop()
}

@Test func rapidStopRestartDoesNotReuseAnOldAcceptLoop() async throws {
    let path = shortSocketPath()
    let received = Received()
    let server = EventServer(path: path) { received.add($0) }
    defer { server.stop() }

    for _ in 0..<50 {
        try server.start()
        server.stop()
    }
    try server.start()
    #expect(UnixSocket.send(Data("final\n".utf8), to: path))
    await waitFor { received.all.count == 1 }
    #expect(received.all == [Data("final".utf8)])
}

@Test func oversizedLineIsDroppedWithoutStoppingTheServer() async throws {
    let path = shortSocketPath()
    let received = Received()
    let server = EventServer(path: path, maximumLineBytes: 32) { received.add($0) }
    try server.start()
    defer { server.stop() }

    let oversizedConnection = Data((String(repeating: "x", count: 100) + "\nnot-delivered\n").utf8)
    #expect(UnixSocket.send(oversizedConnection, to: path))
    #expect(UnixSocket.send(Data("valid\n".utf8), to: path))

    await waitFor { received.all.contains(Data("valid".utf8)) }
    #expect(received.all == [Data("valid".utf8)])
}

@Test func serverNeverDeletesARegularFileAtItsSocketPath() throws {
    let path = shortSocketPath()
    let contents = Data("keep me".utf8)
    try contents.write(to: URL(fileURLWithPath: path), options: .atomic)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let server = EventServer(path: path) { _ in }
    var rejectedOccupiedPath = false
    do {
        try server.start()
    } catch EventServerError.pathOccupied {
        rejectedOccupiedPath = true
    }
    #expect(rejectedOccupiedPath)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == contents)
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
