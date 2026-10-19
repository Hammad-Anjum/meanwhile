import Foundation

/// One thing an agent did, in the shared shape every agent's adapter produces
/// (docs/integrations.md, "Shared event schema"). Everything after the adapters is agent-agnostic.
public struct AgentEvent: Sendable, Equatable, Codable {
    public enum Agent: String, Sendable, Codable {
        case claude, codex, cursor
    }

    public var agent: Agent
    public var session: String
    /// The agent's id for the current turn, when it sends one (Codex `turn_id`, Claude `prompt_id`).
    public var turn: String?
    /// Set when a subagent did this rather than the main agent.
    public var subagent: String?
    public var timestamp: Date
    public var cwd: String
    public var transcript: String?
    public var terminal: Terminal
    public var kind: Kind

    public init(agent: Agent, session: String, turn: String? = nil, subagent: String? = nil,
                timestamp: Date, cwd: String, transcript: String? = nil,
                terminal: Terminal = Terminal(), kind: Kind) {
        self.agent = agent
        self.session = session
        self.turn = turn
        self.subagent = subagent
        self.timestamp = timestamp
        self.cwd = cwd
        self.transcript = transcript
        self.terminal = terminal
        self.kind = kind
    }
}

/// What the hook captured about the agent's terminal or editor, so the app can find it later.
public struct Terminal: Sendable, Equatable, Codable {
    public var program: String?
    public var sessionID: String?
    public var bundleID: String?
    public var parentPID: Int?

    public init(program: String? = nil, sessionID: String? = nil, bundleID: String? = nil, parentPID: Int? = nil) {
        self.program = program
        self.sessionID = sessionID
        self.bundleID = bundleID
        self.parentPID = parentPID
    }
}

extension AgentEvent {
    public enum Kind: Sendable, Equatable, Codable {
        case sessionStart(source: String?)
        case turnStart(prompt: String)
        case read(path: String)
        case edit([FileEdit])
        case exec(command: String, output: String?, failed: Bool)
        case web(WebActivity)
        /// Any other tool call. Still means the agent is working.
        case tool(name: String)
        /// The agent may ask the user. Not proof that it is waiting: Claude Code sends this
        /// even for calls auto mode approves. `needsInput` is the reliable signal.
        case permissionRequest(tool: String, detail: String?)
        case needsInput(reason: String)
        case notification(type: String?, message: String?)
        case turnEnd(lastMessage: String?, outcome: TurnOutcome)
        case subagentEnd(lastMessage: String?)
        case sessionEnd(reason: String?)

        /// The schema's dotted name, e.g. `tool.read`. Stable; used for storage and logs.
        public var name: String {
            switch self {
            case .sessionStart: "session.start"
            case .turnStart: "turn.start"
            case .read: "tool.read"
            case .edit: "tool.edit"
            case .exec: "tool.exec"
            case .web: "tool.web"
            case .tool: "tool.other"
            case .permissionRequest: "permission.request"
            case .needsInput: "needs.input"
            case .notification: "notification"
            case .turnEnd: "turn.end"
            case .subagentEnd: "subagent.end"
            case .sessionEnd: "session.end"
            }
        }
    }

    public enum TurnOutcome: String, Sendable, Codable {
        case completed, failed, interrupted
    }
}

/// One file's change. Lines are without their diff prefix; context lines are dropped.
public struct FileEdit: Sendable, Equatable, Codable {
    public enum Change: String, Sendable, Codable {
        case added, modified, deleted
    }

    public var path: String
    public var change: Change
    public var added: [String]
    public var removed: [String]
    /// Set when the file was renamed (Codex `*** Move to:`).
    public var movedTo: String?

    public init(path: String, change: Change, added: [String] = [], removed: [String] = [], movedTo: String? = nil) {
        self.path = path
        self.change = change
        self.added = added
        self.removed = removed
        self.movedTo = movedTo
    }
}

/// Web searches and page fetches from one tool call.
public struct WebActivity: Sendable, Equatable, Codable {
    public struct Link: Sendable, Equatable, Codable {
        public var title: String
        public var url: String
        public init(title: String, url: String) {
            self.title = title
            self.url = url
        }
    }

    public var queries: [String]
    public var urls: [String]
    public var links: [Link]
    /// The text the agent got back: a search summary or the fetched page. Capped.
    public var text: String?

    public init(queries: [String] = [], urls: [String] = [], links: [Link] = [], text: String? = nil) {
        self.queries = queries
        self.urls = urls
        self.links = links
        self.text = text
    }
}
