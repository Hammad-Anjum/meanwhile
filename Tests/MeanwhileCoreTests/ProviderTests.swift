import Foundation
import Testing
import MeanwhileIPC
@testable import MeanwhileCore

/// Task 2.1: the CLI question models (against fake CLIs) and the generation budget.

/// Writes an executable script and returns its path.
private func fakeCLI(_ name: String, _ body: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data("#!/bin/zsh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

private var schema: [String: Any] { ["type": "object"] }

@Test func codexAnswerIsReadFromTheOutputFile() throws {
    // Writes the answer to the file after -o, after checking how it was called.
    let codex = try fakeCLI("codex", #"""
    out=""; schema=""; shell_disabled=""
    while [ $# -gt 0 ]; do
      case "$1" in -o) out="$2"; shift;; --output-schema) schema="$2"; shift;; --disable) [ "$2" = "shell_tool" ] && shell_disabled=1; shift;; esac; shift
    done
    [ "$MEANWHILE_INTERNAL" = "1" ] || { echo "not internal" >&2; exit 3; }
    [ -z "$(ls -A . | grep -v schema.json)" ] || { echo "cwd not empty" >&2; exit 4; }
    [ -s "$schema" ] || { echo "no schema" >&2; exit 5; }
    [ "$shell_disabled" = "1" ] || { echo "shell tool enabled" >&2; exit 7; }
    [ "$(cat)" = "p" ] || { echo "prompt not on stdin" >&2; exit 6; }
    echo '{"question":"Q?"}' > "$out"
    """#)
    let answer = try CodexCLIModel(executable: codex).generate(prompt: "p", schema: schema)
    #expect(String(decoding: answer, as: UTF8.self).contains("Q?"))
}

@Test func codexFailureIsReported() throws {
    let codex = try fakeCLI("codex", "echo 'usage limit reached' >&2; exit 1")
    #expect(throws: ModelError.failed("usage limit reached\n")) {
        try CodexCLIModel(executable: codex).generate(prompt: "p", schema: schema)
    }
}

@Test func codexTimesOut() throws {
    let codex = try fakeCLI("codex", "sleep 5")
    #expect(throws: ModelError.timedOut(0.5)) {
        try CodexCLIModel(executable: codex, timeout: 0.5).generate(prompt: "p", schema: schema)
    }
}

@Test func claudeStructuredOutputIsUnwrapped() throws {
    let claude = try fakeCLI("claude", #"echo '{"is_error":false,"structured_output":{"question":"Q?"}}'"#)
    let answer = try ClaudeCLIModel(executable: claude).generate(prompt: "p", schema: schema)
    #expect(try JSONSerialization.jsonObject(with: answer) as? [String: String] == ["question": "Q?"])

    let failing = try fakeCLI("claude", #"echo '{"is_error":true,"result":"Not logged in"}'"#)
    #expect(throws: ModelError.failed("Not logged in")) {
        try ClaudeCLIModel(executable: failing).generate(prompt: "p", schema: schema)
    }
}

@Test func missingCLIIsNotInstalled() {
    #expect(throws: ModelError.notInstalled("meanwhile-no-such-cli")) {
        try CodexCLIModel(executable: "meanwhile-no-such-cli").generate(prompt: "p", schema: schema)
    }
}

// MARK: - Budget

@Test func oneLiveAndOnePostTurnCallPerTurn() throws {
    let budget = GenerationBudget(library: try LibraryStore(path: nil))
    let t0 = Date()
    try budget.turnStarted(session: "s", at: t0)
    #expect(try budget.allows(.live, session: "s", now: t0))
    try budget.record(.live, provider: "codex", repo: "/r", session: "s", succeeded: true, duration: 6, at: t0.addingTimeInterval(5))
    #expect(try !budget.allows(.live, session: "s", now: t0.addingTimeInterval(10)))
    #expect(try budget.allows(.postTurn, session: "s", now: t0.addingTimeInterval(10)))
    #expect(try budget.allows(.live, session: "other", now: t0.addingTimeInterval(10)), "per session")

    // A new turn resets the per-turn limits.
    try budget.turnStarted(session: "s", at: t0.addingTimeInterval(60))
    #expect(try budget.allows(.live, session: "s", now: t0.addingTimeInterval(61)))
}

@Test func dailyCapCountsFailuresToo() throws {
    let budget = GenerationBudget(library: try LibraryStore(path: nil), dailyLimit: 3)
    let now = Date()
    for index in 0..<3 {
        try budget.record(.primer, provider: "codex", repo: "/r", session: nil, succeeded: index != 1, duration: 1, at: now)
    }
    #expect(try budget.callsToday(now: now) == 3)
    #expect(try !budget.allows(.primer, session: nil, now: now))
    #expect(try !budget.allows(.live, session: "fresh", now: now))
    // Tomorrow the cap is fresh.
    #expect(try budget.allows(.live, session: "fresh", now: now.addingTimeInterval(24 * 3600)))
}

@Test func workerTurnStartResetsTheBudget() throws {
    let repo = try makeGitRepo(["a.md": "a"])
    defer { try? FileManager.default.removeItem(at: repo) }
    let library = try LibraryStore(path: nil)
    let budget = GenerationBudget(library: library)
    // Dated a second back: stored times have millisecond precision, and the worker's turn
    // start would otherwise land in the same millisecond as this call.
    try budget.record(.live, provider: "codex", repo: repo.path, session: "s", succeeded: true, duration: 1,
                      at: Date().addingTimeInterval(-1))
    #expect(try !budget.allows(.live, session: "s"))
    let lock = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)").path
    try Worker(library: library, lockPath: lock).submit(.init(directory: repo.path, reason: .turnStart, session: "s"))
    #expect(try budget.allows(.live, session: "s"))
}
