import Foundation

/// What one agent session is doing, as far as Meanwhile can tell from its events.
public struct SessionState: Sendable, Equatable {
    public enum Phase: String, Sendable {
        /// Session open, no turn running.
        case idle
        /// The agent is working on a prompt: the time Meanwhile asks questions.
        case working
        /// The agent is waiting for the user mid-turn (a permission prompt, a question).
        case needsInput
        /// A turn just finished. Becomes idle after `Timing.doneLinger`.
        case done
        /// The session closed. Only appears in a `SessionTransition`; the session is then forgotten.
        case ended
    }

    public let session: String
    public let agent: AgentEvent.Agent
    public var cwd: String
    public var terminal: Terminal
    public var phase: Phase
    public var phaseSince: Date
    public var lastActivity: Date
    public var turnStartedAt: Date?
    public var turnCount: Int
    public var lastPrompt: String?
    public var lastOutcome: AgentEvent.TurnOutcome?
    /// A Codex permission request not yet followed by any other event.
    var pendingPermissionSince: Date?
}

public struct SessionTransition: Sendable, Equatable {
    public let session: String
    public let from: SessionState.Phase
    public let to: SessionState.Phase
    public let at: Date
}

/// Turns the event stream into per-session phases. A value type with no clock of its own:
/// `apply` handles events, `tick` handles time passing. Both return the phase changes.
public struct SessionTracker: Sendable {
    public struct Timing: Sendable {
        /// Codex has no needs-input event. A permission request with nothing after it for
        /// this long is taken to mean Codex is waiting on the user.
        public var codexPermissionWait: TimeInterval = 8
        /// How long `done` lasts before the session counts as idle.
        public var doneLinger: TimeInterval = 60
        /// A working session with no events this long is assumed dead and set idle.
        public var staleWorking: TimeInterval = 30 * 60

        public init() {}
    }

    public var timing: Timing
    public private(set) var sessions: [String: SessionState] = [:]

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// The session the notch should follow: the most recently changed one that is
    /// working, waiting on the user, or just done.
    public var focused: SessionState? {
        sessions.values
            .filter { $0.phase != .idle }
            .max { $0.phaseSince < $1.phaseSince }
    }

    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> SessionTransition? {
        let at = event.timestamp
        var state = sessions[event.session] ?? SessionState(
            session: event.session, agent: event.agent, cwd: event.cwd, terminal: event.terminal,
            phase: .idle, phaseSince: at, lastActivity: at, turnCount: 0
        )
        state.lastActivity = max(state.lastActivity, at)
        state.cwd = event.cwd
        let before = state.phase
        let isMainAgent = event.subagent == nil

        switch event.kind {
        case .sessionStart:
            break
        case .turnStart(let prompt) where isMainAgent:
            state.turnStartedAt = at
            state.turnCount += 1
            state.lastPrompt = prompt
            state.lastOutcome = nil
            state.pendingPermissionSince = nil
            state.terminal = event.terminal
            state.phase = .working
        case .turnEnd(_, let outcome) where isMainAgent:
            state.lastOutcome = outcome
            state.pendingPermissionSince = nil
            state.phase = .done
        case .needsInput:
            // Only a running turn can be blocked on the user. Claude's `idle_prompt` after
            // a turn ended just means "waiting for the next prompt", so done stays done.
            if state.phase == .working {
                state.pendingPermissionSince = nil
                state.phase = .needsInput
            }
        case .permissionRequest:
            // Claude Code also sends this for calls auto mode approves; its real signal is
            // `needsInput`. Codex has no such signal, so start the wait clock instead.
            if event.agent == .codex, state.phase == .working {
                state.pendingPermissionSince = at
            }
        case .sessionEnd:
            sessions[event.session] = nil
            return SessionTransition(session: event.session, from: before, to: .ended, at: at)
        case .notification, .subagentEnd, .turnStart, .turnEnd:
            break
        case .read, .edit, .exec, .web, .tool:
            // Activity after a wait means the user answered and the agent carried on.
            state.pendingPermissionSince = nil
            if state.phase == .needsInput { state.phase = .working }
        }

        if state.phase != before { state.phaseSince = at }
        sessions[event.session] = state
        return state.phase == before ? nil : SessionTransition(session: event.session, from: before, to: state.phase, at: at)
    }

    /// Applies the time-based rules as of `now`.
    public mutating func tick(now: Date) -> [SessionTransition] {
        var transitions: [SessionTransition] = []
        for (id, var state) in sessions {
            let before = state.phase
            if state.phase == .working, let since = state.pendingPermissionSince,
               now.timeIntervalSince(since) >= timing.codexPermissionWait {
                state.pendingPermissionSince = nil
                state.phase = .needsInput
            } else if state.phase == .done, now.timeIntervalSince(state.phaseSince) >= timing.doneLinger {
                state.phase = .idle
            } else if state.phase == .working, now.timeIntervalSince(state.lastActivity) >= timing.staleWorking {
                state.phase = .idle
            }
            if state.phase != before {
                state.phaseSince = now
                transitions.append(SessionTransition(session: id, from: before, to: state.phase, at: now))
            }
            sessions[id] = state
        }
        return transitions.sorted { $0.session < $1.session }
    }
}
