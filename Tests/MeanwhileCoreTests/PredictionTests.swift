import Foundation
import Testing
@testable import MeanwhileCore

/// Task 2.10: prediction questions and "this question is wrong".

private let paths = [
    "Sources/API/RateLimiter.swift", "Sources/API/Client.swift", "Sources/API/LimitConfig.swift",
    "Sources/UI/Settings.swift", "Sources/Store/Cache.swift", "docs/rate-limits.md", "Tests/RateLimiterTests.swift",
]

@Test func fileOptionsFollowThePrompt() throws {
    let options = try #require(Prediction.fileOptions(prompt: "Add a rate limit to the API client", paths: paths))
    #expect(options.count == 4)
    #expect(options.first == "Sources/API/RateLimiter.swift", "the file name matches two words")
    #expect(Set(options).isSuperset(of: ["Sources/API/Client.swift", "Sources/API/LimitConfig.swift"]))
    #expect(!options.contains("docs/rate-limits.md"), "only code files")
}

@Test func noPredictionWhenThePromptPointsAtTooLittle() {
    #expect(Prediction.fileOptions(prompt: "Tidy the settings screen", paths: paths) == nil)
    #expect(Prediction.fileOptions(prompt: "the and for", paths: paths) == nil)
}

@Test func recognizesTestRuns() {
    for command in ["swift test", "cd app && npm test", "pnpm run test -- --watch=false", "python -m pytest -q",
                    "go test ./...", "cargo test", "make test", "xcodebuild -scheme App test", "npx vitest run"] {
        #expect(Prediction.isTestCommand(command), "\(command)")
    }
    for command in ["swift build", "git status", "ls tests/", "cat RateLimiterTests.swift"] {
        #expect(!Prediction.isTestCommand(command), "\(command)")
    }
}

private func event(_ kind: AgentEvent.Kind, subagent: String? = nil) -> AgentEvent {
    AgentEvent(agent: .claude, session: "s", subagent: subagent, timestamp: Date(), cwd: "/repo", kind: kind)
}

@Test func theAgentsWorkAnswersPredictions() {
    let events = [
        event(.edit([FileEdit(path: "/repo/Sources/UI/Settings.swift", change: .modified)]), subagent: "helper"),
        event(.exec(command: "swift build", output: nil, failed: false)),
        event(.edit([FileEdit(path: "/repo/Sources/API/Client.swift", change: .modified)])),
        event(.exec(command: "swift test", output: "1 failure", failed: true)),
        event(.exec(command: "swift test", output: "ok", failed: false)),
    ]
    #expect(Prediction.firstEditedFile(events, root: "/repo") == "Sources/API/Client.swift", "subagents don't count")
    #expect(Prediction.firstTestRunPassed(events) == false, "the first run decides")
    #expect(Prediction.firstTestRunPassed([event(.exec(command: "ls", output: nil, failed: false))]) == nil)
}

@Test func reportedCardsNeverShowAgain() throws {
    let store = try ReviewStore(path: nil)
    try store.suppress(cardID: "llm.tokens.1")
    #expect(try store.suppressed() == ["llm.tokens.1"])

    var context = QuestionSelector.Context()
    context.suppressed = try store.suppressed()
    let candidates = [QuestionSelector.Candidate(id: "llm.tokens.1", deck: "llm", deckTitle: "LLM")]
    #expect(QuestionSelector().next(from: candidates, context: context) == nil)
}

@Test func reportedPoolQuestionsLeaveThePool() throws {
    let library = try LibraryStore(path: nil)
    let question = PoolQuestion(id: "cb-1", root: "/r", kind: "live", topic: "t", type: "multipleChoice", question: "Q?",
                                options: ["a", "b", "c", "d"], correct: 0, explanation: "e", quote: "q", sourcePath: "a.swift",
                                evidence: [:], score: 5, createdAt: Date(), status: .ready)
    try library.insert(question)
    #expect(try library.poolQuestions(root: "/r").count == 1)
    try library.setStatus(.reported, question: "cb-1")
    #expect(try library.poolQuestions(root: "/r").isEmpty)
    #expect(try library.poolQuestions(root: "/r", statuses: [.reported]).count == 1)
}
