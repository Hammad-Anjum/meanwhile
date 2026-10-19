import Foundation
import Testing
import MeanwhileIPC
@testable import MeanwhileCore

/// Tasks 2.6, 2.7, 2.9: generators, validation, the pool, staleness and the score gate.

/// Answers with canned JSON and remembers the prompts it got.
private final class FakeModel: QuestionModel, @unchecked Sendable {
    let name = "fake"
    private let lock = NSLock()
    private var _prompts: [String] = []
    var prompts: [String] { lock.withLock { _prompts } }
    var fail = false

    func generate(prompt: String, schema: [String: Any]) throws -> Data {
        lock.withLock { _prompts.append(prompt) }
        if fail { throw ModelError.failed("usage limit") }
        let question = """
        {"question":"How long is the rate limit window in rateLimit()?","type":"multipleChoice",
         "options":["60 seconds","30 seconds","10 seconds","5 minutes"],"correct":0,
         "explanation":"rateLimit() sets window to 60, so requests are counted per minute.",
         "quote":"let window = 60","source_path":"Sources/App.swift","topic":"Rate limiting"}
        """
        if prompt.contains("\"card\"") {
            let primer = """
            {"question":"Which file tells agents how to work in this repo?","type":"multipleChoice",
             "options":["CLAUDE.md","Package.swift","main.swift","Makefile"],"correct":0,
             "explanation":"CLAUDE.md holds the instructions agents read first.",
             "quote":"Agents read this file first","source_path":"CLAUDE.md","topic":"Conventions"}
            """
            return Data(#"{"card":"A Swift app.","questions":[\#(primer)]}"#.utf8)
        }
        return Data(#"{"questions":[\#(question)]}"#.utf8)
    }
}

private func draft(question: String = "How long is the rate limit window?", options: [String] = ["60 seconds", "30 seconds", "10 seconds", "5 minutes"],
                   correct: Int = 0, quote: String = "let window = 60", type: String = "multipleChoice") -> DraftQuestion {
    DraftQuestion(question: question, type: type, options: options, correct: correct,
                  explanation: "It is set in rateLimit().", quote: quote, sourcePath: "Sources/App.swift", topic: "Limits")
}

private let sources = [EvidencePack.Source(path: "Sources/App.swift", blob: nil, text: "func rateLimit() {\n  let window = 60\n}")]

// MARK: - Gate and validator

@Test func contextScoreGatesTheStyle() {
    #expect(QuestionGenerator.style(forScore: 7) == .whatAndWhy)
    #expect(QuestionGenerator.style(forScore: 4) == .whatAndWhy)
    #expect(QuestionGenerator.style(forScore: 3) == .spotTheRisk)
    #expect(QuestionGenerator.style(forScore: 1) == nil)
}

@Test func thinEvidenceNeverCallsTheModel() throws {
    let model = FakeModel()
    let pack = EvidencePack(kind: .live, root: "/r", session: "s", sections: [], sources: [], score: 1,
                            hookOnly: true, editedPaths: [])
    #expect(try QuestionGenerator(model: model).questions(from: pack).isEmpty)
    #expect(model.prompts.isEmpty)
}

@Test func validQuestionPasses() {
    #expect(QuestionValidator.problems(draft(), sources: sources).isEmpty)
    // Different whitespace and punctuation in the quote still match.
    #expect(QuestionValidator.problems(draft(quote: "let  window=60"), sources: sources).isEmpty)
    #expect(QuestionValidator.problems(draft(options: ["True", "False"], correct: 1, type: "trueFalse"), sources: sources).isEmpty)
}

@Test func validatorRejectsBadQuestions() {
    func problems(_ d: DraftQuestion, existing: [String] = []) -> [QuestionValidator.Problem] {
        QuestionValidator.problems(d, sources: sources, existing: existing)
    }
    #expect(problems(draft(question: String(repeating: "x", count: 130))).contains(.tooLong("question")))
    #expect(problems(draft(options: ["a", "b", "c"])).contains(.badOptions))
    #expect(problems(draft(options: ["60 s", "60 s", "1", "2"])).contains(.badOptions))
    #expect(problems(draft(options: ["60 s", String(repeating: "y", count: 60), "1", "2"])).contains(.tooLong("option")))
    #expect(problems(draft(correct: 4)).contains(.badAnswer))
    #expect(problems(draft(quote: "let window = 90")).contains(.quoteNotFound))
    #expect(problems(draft(quote: "")).contains(.quoteMissing))
    #expect(problems(draft(question: "Is the window 60 seconds long?")).contains(.answerInQuestion))
    #expect(problems(draft(), existing: ["How long is the rate-limit window?"]).contains(.duplicate))
}

// MARK: - Pool and staleness

private func repoWithRateLimit() throws -> (URL, LibraryStore) {
    let repo = try makeGitRepo([
        "Sources/App.swift": "func rateLimit() {\n  let window = 60\n}\n",
        "CLAUDE.md": "# Repo\nAgents read this file first. Run make test before committing.",
    ])
    let library = try LibraryStore(path: nil)
    let indexed = try RepoIndexer(library: library).index(root: repo.path)
    try DocIndexer(library: library).process(root: repo.path, newBlobs: indexed.newBlobs)
    return (repo, library)
}

@Test func poolKeepsValidQuestionsAndRetiresThemWhenCodeChanges() throws {
    let (repo, library) = try repoWithRateLimit()
    defer { try? FileManager.default.removeItem(at: repo) }
    let pack = EvidencePack(kind: .postTurn, root: repo.path, session: "s", sections: [],
                            sources: [.init(path: "Sources/App.swift", blob: nil, text: "let window = 60")],
                            score: 5, hookOnly: false, editedPaths: ["Sources/App.swift"])
    let result = try library.addToPool([draft(), draft(quote: "invented")], from: pack, kind: "post-turn")
    #expect(result.added.count == 1 && result.rejected.count == 1)
    let pooled = try #require(try library.poolQuestions(root: repo.path).first)
    #expect(pooled.evidence["Sources/App.swift"] == (try library.blob(of: "Sources/App.swift", root: repo.path)))

    // Same code, no staleness; changed code retires it.
    #expect(try library.markStaleQuestions(root: repo.path) == 0)
    try Data("func rateLimit() {\n  let window = 30\n}\n".utf8).write(to: repo.appendingPathComponent("Sources/App.swift"))
    try RepoIndexer(library: library).index(root: repo.path)
    #expect(try library.markStaleQuestions(root: repo.path) == 1)
    #expect(try library.poolQuestions(root: repo.path).isEmpty)
    #expect(try library.poolQuestions(root: repo.path, statuses: [.stale]).count == 1)
}

// MARK: - Worker end to end

private func line(_ event: String, _ fields: [String: Any], root: URL) throws -> Data {
    var payload = fields
    payload["hook_event_name"] = event
    payload["session_id"] = "s"
    payload["cwd"] = root.path
    return Wire.envelope(agent: "claude", event: event, payload: try JSONSerialization.data(withJSONObject: payload),
                         environment: [:], parentPID: 1)
}

@Test func workerWritesLiveAndPostTurnQuestionsWithinBudget() throws {
    let (repo, library) = try repoWithRateLimit()
    defer { try? FileManager.default.removeItem(at: repo) }
    try library.setState(.on, root: repo.path)
    let events = try EventStore(path: nil)
    let model = FakeModel()
    let lock = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)").path
    let worker = Worker(library: library, lockPath: lock, model: model, events: events, eventSettle: 0)
    let edit: [String: Any] = ["tool_name": "Edit", "tool_input": ["file_path": repo.path + "/Sources/App.swift",
                               "old_string": "let window = 30", "new_string": "let window = 60"], "tool_response": [:]]

    try events.ingest(try line("UserPromptSubmit", ["prompt": "Add a rate limit"], root: repo))
    try worker.submit(.init(directory: repo.path, reason: .turnStart, session: "s"))
    #expect(try library.repoCard(root: repo.path) == "A Swift app.", "primed on first sight")

    try events.ingest(try line("PostToolUse", edit, root: repo))
    try worker.submit(.init(directory: repo.path, reason: .edit, session: "s"))
    try worker.submit(.init(directory: repo.path, reason: .edit, session: "s"))
    let liveCalls = model.prompts.filter { !$0.contains("\"card\"") }.count
    #expect(liveCalls == 1, "one live call per turn")

    try events.ingest(try line("Stop", ["last_assistant_message": "Set the window to 60 s."], root: repo))
    try worker.submit(.init(directory: repo.path, reason: .turnEnd, session: "s"))
    #expect(model.prompts.filter { !$0.contains("\"card\"") }.count == 2, "plus one post-turn call")
    #expect(model.prompts.last?.contains("Set the window to 60 s.") == true, "post-turn sees the summary")

    let pool = try library.poolQuestions(root: repo.path)
    #expect(pool.contains { $0.kind == "primer" } && pool.contains { $0.kind == "live" })
    #expect(try GenerationBudget(library: library).callsToday() == 3)
}

@Test func failingModelIsLoggedNotFatal() throws {
    let (repo, library) = try repoWithRateLimit()
    defer { try? FileManager.default.removeItem(at: repo) }
    try library.setState(.on, root: repo.path)
    let events = try EventStore(path: nil)
    let model = FakeModel()
    model.fail = true
    let lock = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)").path
    let worker = Worker(library: library, lockPath: lock, model: model, events: events, eventSettle: 0)
    try events.ingest(try line("UserPromptSubmit", ["prompt": "x"], root: repo))
    try events.ingest(try line("PostToolUse", ["tool_name": "Write", "tool_input": ["file_path": repo.path + "/Sources/App.swift",
                                                                                   "content": "let window = 60"]], root: repo))
    try worker.submit(.init(directory: repo.path, reason: .edit, session: "s"))
    #expect(try library.poolQuestions(root: repo.path).isEmpty)
    #expect(try GenerationBudget(library: library).callsToday() == 2, "primer and live, both failed, both counted")
}
