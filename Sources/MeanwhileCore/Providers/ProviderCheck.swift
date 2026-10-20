import Foundation

/// One tiny real call to the question provider, to learn whether it works before any
/// codebase question depends on it. An expired Claude login went unnoticed when setup only
/// checked that the CLI was on PATH. Used by `meanwhile setup`, and fit for a `doctor`.
public enum ProviderCheck {
    public enum Result: Sendable, Equatable {
        /// The provider answered with valid JSON after this many seconds.
        case answered(seconds: TimeInterval)
        case notInstalled
        /// The CLI ran but reported a missing or expired login.
        case notLoggedIn(String)
        case timedOut(TimeInterval)
        /// Any other failure, with the CLI's own short explanation.
        case failed(String)

        public var succeeded: Bool {
            if case .answered = self { true } else { false }
        }
    }

    /// The providers Meanwhile can call.
    public static let providers = ["codex", "claude"]

    /// Asks `provider` ("codex" or "claude") for a one-field JSON answer. Prints nothing.
    /// `executable` replaces the CLI found on PATH (for tests).
    public static func run(provider: String, timeout: TimeInterval = 60, executable: String? = nil) -> Result {
        let model: QuestionModel = provider == "claude"
            ? ClaudeCLIModel(executable: executable ?? "claude", timeout: timeout)
            : CodexCLIModel(executable: executable ?? "codex", timeout: timeout)
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["ok"], "properties": ["ok": ["type": "boolean"]],
        ]
        let start = Date()
        do {
            _ = try model.generate(prompt: "Reply with {\"ok\": true}.", schema: schema)
            return .answered(seconds: Date().timeIntervalSince(start))
        } catch let error as ModelError {
            return result(for: error)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Sorts a model error into what the user has to do about it.
    static func result(for error: ModelError) -> Result {
        switch error {
        case .notInstalled: return .notInstalled
        case .timedOut(let seconds): return .timedOut(seconds)
        case .badOutput(let message): return .failed(summary(message))
        case .failed(let message):
            return looksLikeLogin(message) ? .notLoggedIn(summary(message)) : .failed(summary(message))
        }
    }

    /// What the CLIs print for a missing, expired or rejected login.
    static func looksLikeLogin(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["not logged in", "/login", "codex login", "log in", "login", "logged out", "unauthorized",
                "authentication", "invalid api key", "oauth", "token has expired", "credentials"]
            .contains { text.contains($0) }
    }

    /// The last non-empty line of a CLI's message, kept short.
    static func summary(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        return line.count > 160 ? String(line.prefix(157)) + "..." : line
    }

    /// One line for the terminal: "✓ codex answered in 4 s", or what went wrong and the fix.
    public static func message(for result: Result, provider: String) -> String {
        switch result {
        case .answered(let seconds):
            "✓ \(provider) answered in \(max(1, Int(seconds.rounded()))) s"
        case .notInstalled:
            "! \(provider) is not installed. Fix: \(installFix(provider))."
        case .notLoggedIn(let detail):
            "! \(provider) is not logged in\(detail.isEmpty ? "" : " (\(detail))"). Fix: \(loginFix(provider))."
        case .timedOut(let seconds):
            "! \(provider) didn't answer within \(Int(seconds)) s. Run `\(provider)` to check it works; "
                + "if it asks you to log in: \(loginFix(provider))."
        case .failed(let detail):
            "! \(provider) failed\(detail.isEmpty ? "" : ": \(detail)"). If that's a login problem: \(loginFix(provider))."
        }
    }

    static func loginFix(_ provider: String) -> String {
        provider == "claude" ? "run `claude`, then type `/login`" : "run `codex login`"
    }

    static func installFix(_ provider: String) -> String {
        provider == "claude"
            ? "npm install -g @anthropic-ai/claude-code, then run `claude` and type `/login`"
            : "npm install -g @openai/codex (or brew install codex), then run `codex login`"
    }
}
