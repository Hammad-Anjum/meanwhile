import Foundation
import GRDB

/// A validated codebase question, ready for the notch (task 2.6).
public struct PoolQuestion: Sendable, Equatable {
    public enum Status: String, Sendable {
        case ready
        /// A file it cites has changed since (task 2.7).
        case stale
        /// "This question is wrong" (task 2.10).
        case reported
        case retired
    }

    public let id: String
    public let root: String
    public let kind: String
    public let topic: String
    public let type: String
    public let question: String
    public let options: [String]
    public let correct: Int
    public let explanation: String
    public let quote: String
    public let sourcePath: String
    /// The blob hash of each cited file when the question was made.
    public let evidence: [String: String]
    public let score: Int
    public let createdAt: Date
    public let status: Status
}

extension LibraryStore {
    /// Validates drafts against their pack and adds the good ones. Returns what was added
    /// and what was dropped, with why.
    @discardableResult
    public func addToPool(_ drafts: [DraftQuestion], from pack: EvidencePack, kind: String, at now: Date = Date())
        throws -> (added: [PoolQuestion], rejected: [(DraftQuestion, [QuestionValidator.Problem])]) {
        let existing = try poolQuestions(root: pack.root, statuses: [.ready, .stale, .reported, .retired]).map(\.question)
        var added: [PoolQuestion] = [], rejected: [(DraftQuestion, [QuestionValidator.Problem])] = []
        for draft in drafts {
            let problems = QuestionValidator.problems(draft, sources: pack.sources, existing: existing + added.map(\.question))
            guard problems.isEmpty else { rejected.append((draft, problems)); continue }

            // Cite the current blob of every file the evidence used, so a change retires it.
            var evidence: [String: String] = [:]
            for path in Set(pack.sources.map(\.path) + [draft.sourcePath]) {
                if let blob = try blob(of: path, root: pack.root) { evidence[path] = blob }
            }
            let question = PoolQuestion(
                id: "cb-" + RepoIndexer.fingerprint(Data((pack.root + draft.question + draft.quote).utf8)),
                root: pack.root, kind: kind, topic: draft.topic, type: draft.type, question: draft.question,
                options: draft.type == "trueFalse" ? ["True", "False"] : draft.options, correct: draft.correct,
                explanation: draft.explanation, quote: draft.quote, sourcePath: draft.sourcePath,
                evidence: evidence, score: pack.score, createdAt: now, status: .ready)
            try insert(question)
            added.append(question)
        }
        return (added, rejected)
    }

    func insert(_ question: PoolQuestion) throws {
        let repoID = try repoID(root: question.root)
        let options = String(decoding: try JSONEncoder().encode(question.options), as: UTF8.self)
        let evidence = String(decoding: try JSONEncoder().encode(question.evidence), as: UTF8.self)
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO poolQuestion (id, repoId, kind, topic, type, question, options, correct,
                  explanation, quote, sourcePath, evidence, score, promptVersion, createdAt, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [question.id, repoID, question.kind, question.topic, question.type, question.question,
                                 options, question.correct, question.explanation, question.quote, question.sourcePath,
                                 evidence, question.score, QuestionGenerator.promptVersion, question.createdAt,
                                 question.status.rawValue])
        }
    }

    public func poolQuestions(root: String, statuses: Set<PoolQuestion.Status> = [.ready]) throws -> [PoolQuestion] {
        try writer.read { db in
            let marks = Array(repeating: "?", count: statuses.count).joined(separator: ",")
            return try Row.fetchAll(db, sql: """
                SELECT q.*, r.root FROM poolQuestion q JOIN repo r ON r.id = q.repoId
                WHERE r.root = ? AND q.status IN (\(marks)) ORDER BY q.createdAt DESC
                """, arguments: StatementArguments([root] + statuses.map(\.rawValue)))
                .map(Self.poolQuestion)
        }
    }

    /// All tracked file paths of a repo, for prediction options.
    public func filePaths(root: String) throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT f.path FROM fileEntry f JOIN repo r ON r.id = f.repoId WHERE r.root = ?
                """, arguments: [root])
        }
    }

    public func setStatus(_ status: PoolQuestion.Status, question id: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE poolQuestion SET status = ? WHERE id = ?", arguments: [status.rawValue, id])
        }
    }

    /// Marks ready questions stale when a file they cite has a different blob now, or is gone.
    /// Run after each re-index. Returns how many went stale.
    @discardableResult
    public func markStaleQuestions(root: String) throws -> Int {
        var stale = 0
        for question in try poolQuestions(root: root) {
            for (path, blob) in question.evidence where try self.blob(of: path, root: root) != blob {
                try setStatus(.stale, question: question.id)
                stale += 1
                break
            }
        }
        return stale
    }

    // MARK: Repo card (primer)

    public func repoCard(root: String) throws -> String? {
        try writer.read { try String.fetchOne($0, sql: "SELECT card FROM repo WHERE root = ?", arguments: [root]) }
    }

    public func setRepoCard(_ card: String, root: String, at now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE repo SET card = ?, primedAt = ? WHERE root = ?", arguments: [card, now, root])
        }
    }

    public func isPrimed(root: String) throws -> Bool {
        try writer.read { try Date.fetchOne($0, sql: "SELECT primedAt FROM repo WHERE root = ?", arguments: [root]) != nil }
    }

    private static func poolQuestion(_ row: Row) -> PoolQuestion {
        let options = (try? JSONDecoder().decode([String].self, from: Data((row["options"] as String).utf8))) ?? []
        let evidence = (try? JSONDecoder().decode([String: String].self, from: Data((row["evidence"] as String).utf8))) ?? [:]
        return PoolQuestion(id: row["id"], root: row["root"], kind: row["kind"], topic: row["topic"], type: row["type"],
                            question: row["question"], options: options, correct: row["correct"],
                            explanation: row["explanation"], quote: row["quote"], sourcePath: row["sourcePath"],
                            evidence: evidence, score: row["score"], createdAt: row["createdAt"],
                            status: PoolQuestion.Status(rawValue: row["status"]) ?? .ready)
    }
}
