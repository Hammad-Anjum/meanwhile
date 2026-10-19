import Foundation
import Testing
@testable import MeanwhileCore

/// Task 1.3: every session phase transition.

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func event(_ kind: AgentEvent.Kind, at seconds: TimeInterval = 0, agent: AgentEvent.Agent = .claude,
                   session: String = "s", subagent: String? = nil) -> AgentEvent {
    AgentEvent(agent: agent, session: session, subagent: subagent, timestamp: t0.addingTimeInterval(seconds),
               cwd: "/repo", kind: kind)
}

private let prompt = AgentEvent.Kind.turnStart(prompt: "fix the bug")
private let toolCall = AgentEvent.Kind.exec(command: "swift test", output: nil, failed: false)
private let stop = AgentEvent.Kind.turnEnd(lastMessage: "done", outcome: .completed)

private func phase(_ tracker: SessionTracker, _ session: String = "s") -> SessionState.Phase? {
    tracker.sessions[session]?.phase
}

@Test func sessionStartIsIdle() {
    var tracker = SessionTracker()
    #expect(tracker.apply(event(.sessionStart(source: "startup"))) == nil)
    #expect(phase(tracker) == .idle)
}

@Test func promptStartsWorkingEvenWithoutSessionStart() {
    var tracker = SessionTracker()
    let transition = tracker.apply(event(prompt))
    #expect(transition == SessionTransition(session: "s", from: .idle, to: .working, at: t0))
    #expect(tracker.sessions["s"]?.turnCount == 1 && tracker.sessions["s"]?.lastPrompt == "fix the bug")
}

@Test func workingToNeedsInputAndBack() {
    var tracker = SessionTracker()
    tracker.apply(event(prompt))
    #expect(tracker.apply(event(.needsInput(reason: "permission_prompt"), at: 5))?.to == .needsInput)
    // The user answered; the agent's next tool call resumes the turn.
    #expect(tracker.apply(event(toolCall, at: 20))?.to == .working)
}

@Test func turnEndIsDoneThenIdleAfterLinger() {
    var tracker = SessionTracker()
    tracker.apply(event(prompt))
    #expect(tracker.apply(event(stop, at: 40))?.to == .done)
    #expect(tracker.sessions["s"]?.lastOutcome == .completed)
    #expect(tracker.tick(now: t0.addingTimeInterval(40 + 59)).isEmpty)
    #expect(tracker.tick(now: t0.addingTimeInterval(40 + 60)).map(\.to) == [.idle])
}

@Test func doneToWorkingOnNextPrompt() {
    var tracker = SessionTracker()
    tracker.apply(event(prompt))
    tracker.apply(event(stop, at: 10))
    #expect(tracker.apply(event(prompt, at: 15))?.to == .working)
    #expect(tracker.sessions["s"]?.turnCount == 2 && tracker.sessions["s"]?.lastOutcome == nil)
}

@Test func needsInputToDoneWhenTheTurnEnds() {
    var tracker = SessionTracker()
    tracker.apply(event(prompt))
    tracker.apply(event(.needsInput(reason: "permission_prompt"), at: 1))
    #expect(tracker.apply(event(.turnEnd(lastMessage: nil, outcome: .interrupted), at: 3))?.to == .done)
    #expect(tracker.sessions["s"]?.lastOutcome == .interrupted)
}

@Test func idlePromptAfterTheTurnKeepsDone() {
    var tracker = SessionTracker()
    tracker.apply(event(prompt))
    tracker.apply(event(stop, at: 10))
    #expect(tracker.apply(event(.needsInput(reason: "idle_prompt"), at: 70)) == nil)
    #expect(phase(tracker) == .done)
}

@Test func claudePermissionRequestIsNotWaiting() {
    var tracker = SessionTracker()
    tracker.apply(event(prompt))
    #expect(tracker.apply(event(.permissionRequest(tool: "Bash", detail: "ls"), at: 1)) == nil)
    #expect(tracker.tick(now: t0.addingTimeInterval(60)).isEmpty)
    #expect(phase(tracker) == .working)
}

@Test func codexPermissionRequestWithNothingAfterMeansWaiting() {
    var tracker = SessionTracker()
    tracker.apply(event(prompt, agent: .codex))
    tracker.apply(event(.permissionRequest(tool: "Bash", detail: "rm -rf build"), at: 1, agent: .codex))
    #expect(tracker.tick(now: t0.addingTimeInterval(8)).isEmpty)
    #expect(tracker.tick(now: t0.addingTimeInterval(9)).map(\.to) == [.needsInput])
    #expect(tracker.apply(event(toolCall, at: 30, agent: .codex))?.to == .working)
}

@Test func codexPermissionFollowedByActivityStaysWorking() {
    var tracker = SessionTracker()
    tracker.apply(event(prompt, agent: .codex))
    tracker.apply(event(.permissionRequest(tool: "Bash", detail: "swift build"), at: 1, agent: .codex))
    tracker.apply(event(toolCall, at: 3, agent: .codex))
    #expect(tracker.tick(now: t0.addingTimeInterval(30)).isEmpty)
    #expect(phase(tracker) == .working)
}

@Test func silentWorkingSessionGoesIdle() {
    var tracker = SessionTracker()
    tracker.apply(event(prompt))
    tracker.apply(event(toolCall, at: 60))
    #expect(tracker.tick(now: t0.addingTimeInterval(60 + 29 * 60)).isEmpty)
    #expect(tracker.tick(now: t0.addingTimeInterval(60 + 30 * 60)).map(\.to) == [.idle])
}

@Test func sessionEndForgetsTheSession() {
    var tracker = SessionTracker()
    tracker.apply(event(prompt))
    #expect(tracker.apply(event(.sessionEnd(reason: "exit"), at: 5)) == SessionTransition(session: "s", from: .working, to: .ended, at: t0.addingTimeInterval(5)))
    #expect(tracker.sessions["s"] == nil)
}

@Test func subagentsCountAsActivityButNotAsTurns() {
    var tracker = SessionTracker()
    tracker.apply(event(prompt))
    tracker.apply(event(.needsInput(reason: "permission_prompt"), at: 1))
    #expect(tracker.apply(event(toolCall, at: 2, subagent: "a1"))?.to == .working)
    // A subagent's own turn ending is not the main turn ending.
    #expect(tracker.apply(event(stop, at: 3, subagent: "a1")) == nil)
    #expect(tracker.apply(event(.subagentEnd(lastMessage: nil), at: 4)) == nil)
    #expect(phase(tracker) == .working)
}

@Test func focusFollowsTheLatestActiveSession() {
    var tracker = SessionTracker()
    tracker.apply(event(prompt, session: "a"))
    tracker.apply(event(prompt, at: 5, session: "b"))
    #expect(tracker.focused?.session == "b")
    tracker.apply(event(stop, at: 10, session: "b"))
    tracker.apply(event(.sessionEnd(reason: nil), at: 11, session: "b"))
    #expect(tracker.focused?.session == "a")
}

@Test(arguments: ["claude-read-websearch-edit-permission", "codex-websearch-patch", "codex-second-run"])
func recordedSessionsEndDone(name: String) throws {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "ndjson", subdirectory: "Fixtures"))
    var tracker = SessionTracker()
    var phases: [SessionState.Phase] = []
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
        for event in EventAdapter.events(fromLine: Data(line.utf8)) {
            if let transition = tracker.apply(event) { phases.append(transition.to) }
        }
    }
    #expect(phases.first == .working)
    #expect(phases.last == .done)
}
