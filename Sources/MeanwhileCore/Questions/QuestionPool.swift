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
        let touched = Set(pack.editedPaths)
        if !touched.isEmpty {
            // Text fingerprints belong to the checkout that made them.
            for old in try poolQuestions(root: pack.root)
                where old.root == pack.root && touched.contains(old.sourcePath)
                && old.evidence.values.contains(where: { $0.hasPrefix("text:") }) {
                try setStatus(.stale, question: old.id)
            }
        }
        // Every worktree's questions: a question asked in one isn't written again in another.
        let pooled = try poolQuestions(root: pack.root, statuses: [.ready, .stale, .reported, .retired])
        let existing = pooled.map(\.question)
        var quotes = Set(pooled.map { Self.quoteKey($0.sourcePath, $0.quote) })
        var added: [PoolQuestion] = [], rejected: [(DraftQuestion, [QuestionValidator.Problem])] = []
        for rawDraft in drafts {
            var draft = rawDraft
            draft.question = Redactor.redact(draft.question)
            draft.options = draft.options.map(Redactor.redact)
            draft.explanation = Redactor.redact(draft.explanation)
            draft.quote = Redactor.redact(draft.quote)
            draft.topic = Redactor.redact(draft.topic)
            var problems = QuestionValidator.problems(draft, sources: pack.sources, transmittedText: pack.text,
                                                       existing: existing + added.map(\.question))
            // The same quote from the same file is the same question, however it's worded.
            if !problems.contains(.duplicate), !quotes.insert(Self.quoteKey(draft.sourcePath, draft.quote)).inserted {
                problems.append(.duplicate)
            }
            guard problems.isEmpty else { rejected.append((rawDraft, problems)); continue }

            // Bind staleness to the source that actually proves the answer. A text fingerprint
            // covers hook-only/untracked evidence until the path enters the Git index.
            var evidence: [String: String] = [:]
            for source in pack.sources where source.path == draft.sourcePath {
                evidence[source.path] = try blob(of: source.path, root: pack.root)
                    ?? source.blob
                    ?? "text:" + RepoIndexer.fingerprint(Data(source.text.utf8))
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

    /// Stored under the project, so every worktree of the repo shares it; `root` (the
    /// checkout it came from) is kept with it.
    func insert(_ question: PoolQuestion) throws {
        let projectID = try repoID(root: try projectRoot(of: question.root))
        let options = String(decoding: try JSONEncoder().encode(question.options), as: UTF8.self)
        let evidence = String(decoding: try JSONEncoder().encode(question.evidence), as: UTF8.self)
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO poolQuestion (id, repoId, checkout, kind, topic, type, question, options, correct,
                  explanation, quote, sourcePath, evidence, score, promptVersion, createdAt, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [question.id, projectID, question.root, question.kind, question.topic, question.type,
                                 question.question, options, question.correct, question.explanation, question.quote,
                                 question.sourcePath, evidence, question.score, QuestionGenerator.promptVersion,
                                 question.createdAt, question.status.rawValue])
        }
    }

    /// The questions of the project `root` belongs to, from all its worktrees.
    public func poolQuestions(root: String, statuses: Set<PoolQuestion.Status> = [.ready]) throws -> [PoolQuestion] {
        let project = try projectRoot(of: root)
        return try writer.read { db in
            let marks = Array(repeating: "?", count: statuses.count).joined(separator: ",")
            return try Row.fetchAll(db, sql: """
                SELECT q.*, COALESCE(q.checkout, r.root) AS root FROM poolQuestion q JOIN repo r ON r.id = q.repoId
                WHERE r.root = ? AND q.status IN (\(marks)) ORDER BY q.createdAt DESC
                """, arguments: StatementArguments([project] + statuses.map(\.rawValue)))
                .compactMap(Self.poolQuestion)
        }
    }

    /// Ready questions that hold in the checkout at `root`: every file they cite has the same
    /// content there. So a question about code only on one branch shows only in that branch's
    /// worktree, and everywhere once it's merged.
    public func poolQuestions(visibleIn root: String) throws -> [PoolQuestion] {
        let files = try fileEntries(repoID: try repoID(root: root))
        return try poolQuestions(root: root).filter { Self.holds($0, in: root, files: files) }
    }

    /// Whether `question`'s evidence matches the checkout whose files are `files`. Text
    /// fingerprints (hook-only evidence) hold only in the checkout that made the question.
    static func holds(_ question: PoolQuestion, in root: String, files: [String: String]) -> Bool {
        question.evidence.allSatisfy { path, blob in
            blob.hasPrefix("text:") ? question.root == root : files[path] == blob
        }
    }

    static func quoteKey(_ path: String, _ quote: String) -> String {
        path + "\u{1f}" + QuestionValidator.normalize(quote)
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

    /// Marks ready questions stale once no checkout of the project has the files they cite
    /// as they were: changed or gone everywhere. Text-fingerprint questions go stale when
    /// their file is edited again (in `addToPool`). Run after each re-index. Returns how many went stale.
    @discardableResult
    public func markStaleQuestions(root: String) throws -> Int {
        let project = try projectRoot(of: root)
        let checkouts = try repos().filter { $0.project == project }.map(\.root)
        let files = try checkouts.map { (root: $0, files: try fileEntries(repoID: try repoID(root: $0))) }
        var stale = 0
        for question in try poolQuestions(root: root) {
            let textOnly = question.evidence.values.allSatisfy { $0.hasPrefix("text:") }
            let holdsSomewhere = files.contains { Self.holds(question, in: $0.root, files: $0.files) }
            // About a file of another checkout nested in this one: not this checkout's code.
            let nested = EvidenceBuilder.isInNestedCheckout(question.sourcePath, root: question.root)
            guard nested || (!textOnly && !holdsSomewhere) else { continue }
            try setStatus(.stale, question: question.id)
            stale += 1
        }
        return stale
    }

    // MARK: Repo card (primer), one per project

    public func repoCard(root: String) throws -> String? {
        let project = try projectRoot(of: root)
        return try writer.read { try String.fetchOne($0, sql: "SELECT card FROM repo WHERE root = ?", arguments: [project]) }
    }

    public func setRepoCard(_ card: String, root: String, at now: Date = Date()) throws {
        let project = try projectRoot(of: root)
        try noteRepo(root: project)
        try writer.write { db in
            try db.execute(sql: "UPDATE repo SET card = ?, primedAt = ? WHERE root = ?", arguments: [card, now, project])
        }
    }

    public func isPrimed(root: String) throws -> Bool {
        let project = try projectRoot(of: root)
        return try writer.read {
            try Date.fetchOne($0, sql: "SELECT primedAt FROM repo WHERE root = ?", arguments: [project]) != nil
        }
    }

    private static func poolQuestion(_ row: Row) -> PoolQuestion? {
        guard let status = PoolQuestion.Status(rawValue: row["status"]),
              let options = try? JSONDecoder().decode([String].self, from: Data((row["options"] as String).utf8)),
              let evidence = try? JSONDecoder().decode([String: String].self, from: Data((row["evidence"] as String).utf8)),
              !options.isEmpty, options.indices.contains(row["correct"] as Int) else { return nil }
        return PoolQuestion(id: row["id"], root: row["root"], kind: row["kind"], topic: row["topic"], type: row["type"],
                            question: row["question"], options: options, correct: row["correct"],
                            explanation: row["explanation"], quote: row["quote"], sourcePath: row["sourcePath"],
                            evidence: evidence, score: row["score"], createdAt: row["createdAt"],
                            status: status)
    }
}
