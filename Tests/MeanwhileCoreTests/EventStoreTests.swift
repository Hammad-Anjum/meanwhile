import Foundation
import Testing
import MeanwhileIPC
@testable import MeanwhileCore

/// Task 1.2: the GRDB event store.

private func fixtureLines(_ name: String) throws -> [Data] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "ndjson", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("meanwhile-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func line(session: String, cwd: String = "/repo", prompt: String = "hi") -> Data {
    let payload = try! JSONSerialization.data(withJSONObject: [
        "hook_event_name": "UserPromptSubmit", "session_id": session, "cwd": cwd, "prompt": prompt,
    ])
    return Wire.envelope(agent: "claude", event: "UserPromptSubmit", payload: payload, environment: [:], parentPID: 1)
}

@Test func storesRecordedSessionsAndReadsThemBack() throws {
    let store = try EventStore(path: nil)
    let lines = try fixtureLines("claude-read-websearch-edit-permission")
    var adapted: [AgentEvent] = []
    for line in lines { adapted += try store.ingest(line) }

    #expect(try store.rawLineCount() == lines.count)
    let session = try #require(adapted.first?.session)
    #expect(try store.events(inSession: session) == adapted)
}

@Test func eventsSurviveReopening() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("meanwhile.sqlite").path

    let lines = try fixtureLines("codex-websearch-patch")
    var stored: [AgentEvent] = []
    do {
        let store = try EventStore(path: path)
        for line in lines { stored += try store.ingest(line) }
    }

    let reopened = try EventStore(path: path)
    let session = try #require(stored.first?.session)
    #expect(try reopened.events(inSession: session) == stored)
    #expect(try reopened.rawLineCount() == lines.count)

    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

@Test func pruneDeletesOnlyLinesPastRetention() throws {
    let store = try EventStore(path: nil)
    let now = Date()
    try store.ingest(line(session: "old"), receivedAt: now.addingTimeInterval(-31 * 24 * 3600))
    try store.ingest(line(session: "new"), receivedAt: now.addingTimeInterval(-29 * 24 * 3600))

    #expect(try store.prune(now: now) == 1)
    #expect(try store.rawLineCount() == 1)
    #expect(try store.events(inSession: "old").isEmpty)
    #expect(try store.events(inSession: "new").count == 1)
}

@Test func queriesFilterByTimeAndDirectory() throws {
    let store = try EventStore(path: nil)
    try store.ingest(line(session: "a", cwd: "/one"))
    try store.ingest(line(session: "b", cwd: "/two"))

    #expect(try store.events(since: .distantPast).count == 2)
    #expect(try store.events(since: .distantPast, cwd: "/two").map(\.session) == ["b"])
    #expect(try store.events(since: .distantFuture).isEmpty)
}

@Test func linesThatAdaptToNothingAreStillKeptRaw() throws {
    let store = try EventStore(path: nil)
    #expect(try store.ingest(Data("not an envelope".utf8)).isEmpty)
    #expect(try store.rawLineCount() == 1)
}
