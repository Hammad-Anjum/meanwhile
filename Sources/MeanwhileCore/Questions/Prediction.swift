import Foundation

/// Prediction questions (task 2.10; docs/question-engine.md "Questions that don't need
/// context"): you commit to a guess about this turn, and the agent's own work answers it.
/// No model call; they never enter spaced repetition.
public enum Prediction {
    public enum Kind: String, Sendable, Equatable {
        /// "Which file will the agent change first?"
        case firstFile
        /// "Will the tests pass on the first run?"
        case testsPass
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "make", "add", "fix", "use", "can", "you",
        "please", "should", "would", "could", "about", "when", "then", "also", "have", "has", "are", "was", "its",
        "not", "but", "all", "any", "new", "our", "out", "how", "why", "what", "where", "which", "there", "here",
        "file", "files", "code", "change", "update", "some", "them", "they", "let", "get", "set",
    ]

    /// Up to 4 files the prompt points at, best first; nil when fewer than 3 match at all,
    /// because a guess between 2 obvious files isn't worth a question.
    public static func fileOptions(prompt: String, paths: [String], count: Int = 4) -> [String]? {
        let words = Set(prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) })
        guard !words.isEmpty else { return nil }
        let scored = paths.compactMap { path -> (String, Int)? in
            guard FileKind.kind(path) == .code else { return nil }
            let lower = path.lowercased()
            let name = ((lower as NSString).lastPathComponent as NSString).deletingPathExtension
            let nameParts = Set(name.split { !$0.isLetter && !$0.isNumber }.map(String.init) + camelParts(path))
            var score = 0
            for word in words {
                if nameParts.contains(word) || name.contains(word) { score += 3 }
                else if lower.contains(word) { score += 1 }
            }
            return score > 0 ? (path, score) : nil
        }
        let best = scored.sorted { ($0.1, $1.0) > ($1.1, $0.0) }.prefix(count).map(\.0)
        return best.count >= 3 ? Array(best) : nil
    }

    /// "RateLimiter.swift" → ["rate", "limiter"]
    private static func camelParts(_ path: String) -> [String] {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var parts: [String] = [], current = ""
        for character in name {
            if character.isUppercase, !current.isEmpty { parts.append(current); current = "" }
            if character.isLetter || character.isNumber { current.append(character) } else if !current.isEmpty { parts.append(current); current = "" }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.map { $0.lowercased() }
    }

    /// Whether a shell command runs a test suite.
    public static func isTestCommand(_ command: String) -> Bool {
        let patterns = [#"\bswift test\b"#, #"\b(npm|pnpm|yarn|bun) (run )?test\b"#, #"\bpytest\b"#, #"\bgo test\b"#,
                        #"\bcargo test\b"#, #"\bmake test\b"#, #"\bxcodebuild\b.*\btest\b"#, #"\bjest\b"#,
                        #"\bvitest\b"#, #"\brspec\b"#, #"\bmix test\b"#, #"\bgradle\w* test\b"#, #"python -m unittest"#]
        return patterns.contains { command.range(of: $0, options: .regularExpression) != nil }
    }

    /// The first file the agent edits in `events`, relative to `root`.
    public static func firstEditedFile(_ events: [AgentEvent], root: String) -> String? {
        for event in events {
            guard event.subagent == nil, case .edit(let edits) = event.kind, let path = edits.first?.path else { continue }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        return nil
    }

    /// Whether the first test run in `events` passed; nil if there was none.
    public static func firstTestRunPassed(_ events: [AgentEvent]) -> Bool? {
        for event in events {
            if case .exec(let command, _, let failed) = event.kind, isTestCommand(command) { return !failed }
        }
        return nil
    }
}
