import Foundation
import Testing
@testable import MeanwhileCore

/// Task 2.5: evidence packs, redaction and the hook-only fallback.

@Test func knownSecretShapesAreMasked() {
    let secrets = [
        "AKIAABCDEFGHIJKLMNOP",
        "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        "sk-ant-api03-abcdefghijklmnopqrstuvwxyz",
        "sk-proj-abcdefghijklmnopqrstuvwxyz012345",
        "xoxb-1234567890-abcdefghij",
        "sk_live_abcdefghijklmnop1234",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
    ]
    for secret in secrets {
        let redacted = Redactor.redact("value: \(secret) end")
        #expect(!redacted.contains(secret), "\(secret)")
        #expect(redacted.contains(Redactor.mask))
    }
    #expect(!Redactor.redact("-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----").contains("MIIEow"))
    #expect(Redactor.redact("postgres://admin:s3cretpw@db:5432/app") == "postgres://[REDACTED]@db:5432/app")
    #expect(Redactor.redact("Authorization: Bearer real_token_123456") == "Authorization: [REDACTED]")
    #expect(Redactor.redact(#"password = "correct horse battery staple""#) == #"password = "[REDACTED]""#)
}

@Test func assignmentsKeepTheNameAndMaskTheValue() {
    #expect(Redactor.redact(#"let password = "hunter2xyz""#) == #"let password = "[REDACTED]""#)
    #expect(Redactor.redact("API_KEY=abcdef123456") == "API_KEY=[REDACTED]")
    #expect(Redactor.redact(#""client_secret": "abc123def456""#) == #""client_secret": "[REDACTED]""#)
    // Ordinary code is left alone.
    #expect(Redactor.redact("let count = items.count + 1") == "let count = items.count + 1")
    #expect(Redactor.redact("tokens: 5") == "tokens: 5")
}

@Test func secretFilesAreNeverRead() {
    for path in [".env", "config/.env.production", "certs/server.pem", "deploy/key.p12", "id_rsa", ".npmrc",
                 ".git-credentials", "credentials.json", "service-account.json", "kubeconfig"] {
        #expect(Redactor.isSecretFile(path), "\(path)")
    }
    for path in [".env.example", "Sources/Env.swift", "README.md", "keys.swift"] {
        #expect(!Redactor.isSecretFile(path), "\(path)")
    }
}

@Test func evidenceRejectsOutsidePathsAndSymlinkReads() throws {
    let (repo, library) = try preparedRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).txt")
    try Data("TOP SECRET OUTSIDE".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    let link = repo.appendingPathComponent("Sources/Link.swift")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    let events = [
        event(.turnStart(prompt: "edit"), repo),
        event(.edit([FileEdit(path: repo.deletingLastPathComponent().appendingPathComponent("outside.swift").path,
                              change: .modified, added: ["outside"])]), repo),
        event(.edit([FileEdit(path: link.path, change: .modified, added: ["safe hook hunk"])]), repo),
    ]
    let pack = try #require(try EvidenceBuilder(library: library).build(kind: .live, root: repo.path, session: "s", events: events))
    #expect(pack.editedPaths == ["Sources/Link.swift"])
    #expect(pack.text.contains("safe hook hunk"))
    #expect(!pack.text.contains("TOP SECRET OUTSIDE"))
}

private func event(_ kind: AgentEvent.Kind, _ root: URL) -> AgentEvent {
    AgentEvent(agent: .claude, session: "s", timestamp: Date(), cwd: root.path, kind: kind)
}

private let appSource = (1...60).map { "// line \($0)" }.joined(separator: "\n")
    + "\nfunc rateLimit() {\n  let window = 60\n  let apiKey = \"AKIAABCDEFGHIJKLMNOP\"\n}\n"
    + (62...100).map { "// line \($0)" }.joined(separator: "\n")

private func preparedRepo() throws -> (URL, LibraryStore) {
    let repo = try makeGitRepo([
        "Sources/App.swift": appSource,
        "Sources/Client.swift": "let client = 1",
        "docs/limits.md": "# Limits\nThe `rateLimit` in Sources/App.swift uses a 60 s window.",
    ])
    let library = try LibraryStore(path: nil)
    let indexed = try RepoIndexer(library: library).index(root: repo.path)
    try DocIndexer(library: library).process(root: repo.path, newBlobs: indexed.newBlobs)
    try HistoryIndexer(library: library).update(root: repo.path)
    return (repo, library)
}

private func turn(_ repo: URL, summary: String? = "Added a 60 s rate limit window.") -> [AgentEvent] {
    var events = [
        event(.turnStart(prompt: "Add rate limiting to the API"), repo),
        event(.read(path: repo.path + "/Sources/Client.swift"), repo),
        event(.edit([FileEdit(path: repo.path + "/Sources/App.swift", change: .modified,
                              added: ["func rateLimit() {", "  let window = 60"], removed: [])]), repo),
    ]
    if let summary { events.append(event(.turnEnd(lastMessage: summary, outcome: .completed), repo)) }
    return events
}

@Test func postTurnPackHasEverySource() throws {
    let (repo, library) = try preparedRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let pack = try #require(try EvidenceBuilder(library: library)
        .build(kind: .postTurn, root: repo.path, session: "s", events: turn(repo)))

    #expect(pack.sections.map(\.title) == ["The user asked the agent", "What the agent changed", "The agent's summary",
                                           "Docs and history about these files", "Other files the agent read"])
    #expect(pack.editedPaths == ["Sources/App.swift"])
    #expect(pack.text.contains("61  func rateLimit() {"), "code around the edit, with line numbers")
    #expect(pack.text.contains("Limits"), "the doc that mentions the file")
    #expect(pack.text.contains("first"), "a commit subject")
    #expect(!pack.text.contains("AKIAABCDEFGHIJKLMNOP"), "redacted")
    #expect(pack.score == 7 && !pack.hookOnly)
    #expect(pack.sources.contains { $0.path == "Sources/App.swift" && $0.blob != nil })
}

@Test func livePackHasNoSummaryAndAScoreToMatch() throws {
    let (repo, library) = try preparedRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let pack = try #require(try EvidenceBuilder(library: library)
        .build(kind: .live, root: repo.path, session: "s", events: turn(repo, summary: nil)))
    #expect(!pack.sections.map(\.title).contains("The agent's summary"))
    #expect(pack.score == 5)
}

@Test func unreadableRepoFallsBackToHookContent() throws {
    let missing = URL(fileURLWithPath: "/nonexistent/repo-\(UUID().uuidString)")
    let library = try LibraryStore(path: nil)
    try library.recordAccess(root: missing.path, fileCount: nil, error: "Operation not permitted")
    let pack = try #require(try EvidenceBuilder(library: library)
        .build(kind: .postTurn, root: missing.path, session: "s", events: turn(missing)))
    #expect(pack.hookOnly)
    #expect(pack.text.contains("+ func rateLimit() {"), "the hunk from the hook event")
    #expect(!pack.text.contains("Current code around the change"))
    #expect(pack.score == 5, "edit, the agent's reason and a related read; no docs or commits without the repo")
}

@Test func packsStayInBudget() throws {
    let (repo, library) = try preparedRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let huge = (1...5_000).map { "let generated\($0) = \($0) // padding padding padding" }
    var events = turn(repo)
    events.insert(event(.edit([FileEdit(path: repo.path + "/Sources/Big.swift", change: .added, added: huge)]), repo), at: 2)
    let pack = try #require(try EvidenceBuilder(library: library)
        .build(kind: .postTurn, root: repo.path, session: "s", events: events))
    #expect(pack.text.count <= 24_000)
    #expect(pack.estimatedTokens <= 6_000)
}

@Test func noEditsNoPack() throws {
    let library = try LibraryStore(path: nil)
    let root = URL(fileURLWithPath: "/r")
    #expect(try EvidenceBuilder(library: library)
        .build(kind: .postTurn, root: root.path, session: "s", events: [event(.turnStart(prompt: "hi"), root)]) == nil)
}

@Test func onlyTheLatestTurnCounts() {
    let root = URL(fileURLWithPath: "/r")
    let events = [event(.turnStart(prompt: "one"), root), event(.read(path: "/r/a"), root),
                  event(.turnStart(prompt: "two"), root), event(.read(path: "/r/b"), root)]
    #expect(EvidenceBuilder.currentTurn(events).count == 2)
}
