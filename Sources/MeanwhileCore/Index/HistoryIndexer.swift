import Foundation
import GRDB

/// Per-file git history for ranking and "why" evidence (task 2.4): how often a file
/// changes, when it last did, and how much of it the user didn't write.
///
/// The first pass reads the last 180 days (at most 5,000 commits); later passes read only
/// commits since the last one seen. A rewritten history starts over.
public struct HistoryIndexer: Sendable {
    public var days = 180
    public var maxCommits = 5_000
    public let library: LibraryStore

    public init(library: LibraryStore) {
        self.library = library
    }

    public struct Commit: Equatable, Sendable {
        public let sha: String
        public let email: String
        public let date: Date
        public let subject: String
        public let paths: [String]
    }

    /// Reads new commits into the library. Returns how many were added.
    @discardableResult
    public func update(root: String) throws -> Int {
        let repoID = try library.repoID(root: root)
        let me = (try? Shell.run("git", ["-C", root, "config", "user.email"]))?.text
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let last = try library.lastHistoryCommit(repoID: repoID)

        var range = ["--since=\(days).days", "--max-count=\(maxCommits)"]
        if let last {
            // Only new commits, if the last one seen is still in the history.
            let ancestor = try Shell.run("git", ["-C", root, "merge-base", "--is-ancestor", last, "HEAD"])
            if ancestor.status == 0 { range = ["\(last)..HEAD"] } else { try library.clearHistory(repoID: repoID) }
        }
        let log = try Shell.run("git", ["-C", root, "log", "--no-merges", "--name-only",
                                        "--format=%x1e%H%x1f%ae%x1f%at%x1f%s"] + range, timeout: 120)
        // An empty repo (no commits yet) has no history; that's not an error.
        guard log.succeeded else { return 0 }
        let commits = Self.parse(log.text)
        guard !commits.isEmpty else { return 0 }

        try library.writer.write { db in
            let insertCommit = try db.makeStatement(sql: """
                INSERT OR IGNORE INTO commitInfo (repoId, sha, email, committedAt, subject) VALUES (?, ?, ?, ?, ?)
                """)
            let touch = try db.makeStatement(sql: """
                INSERT INTO fileHistory (repoId, path, commits, mine, lastCommitAt) VALUES (?, ?, 1, ?, ?)
                ON CONFLICT(repoId, path) DO UPDATE SET commits = commits + 1, mine = mine + excluded.mine,
                  lastCommitAt = MAX(lastCommitAt, excluded.lastCommitAt)
                """)
            // Oldest first, so "last seen" ends at the newest.
            for commit in commits.reversed() {
                try insertCommit.execute(arguments: [repoID, commit.sha, commit.email, commit.date, commit.subject])
                let isMine = !me.isEmpty && commit.email.lowercased() == me
                for path in commit.paths {
                    try touch.execute(arguments: [repoID, path, isMine ? 1 : 0, commit.date])
                }
            }
            try db.execute(sql: "UPDATE repo SET historyHead = ? WHERE id = ?", arguments: [commits[0].sha, repoID])
        }
        return commits.count
    }

    /// Parses `git log --name-only --format=%x1e%H%x1f%ae%x1f%at%x1f%s`, newest first.
    static func parse(_ text: String) -> [Commit] {
        text.split(separator: "\u{1e}").compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let header = lines.first else { return nil }
            let fields = header.split(separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, let seconds = TimeInterval(fields[2]) else { return nil }
            return Commit(sha: String(fields[0]), email: String(fields[1]), date: Date(timeIntervalSince1970: seconds),
                          subject: String(fields[3]), paths: lines.dropFirst().map(String.init))
        }
    }
}

extension LibraryStore {
    public struct FileHistory: Sendable, Equatable {
        public let commits: Int
        public let mine: Int
        public let lastCommitAt: Date?

        /// Share of the file's recent commits made by someone else (or by the agent through
        /// someone else's account): the "not yours" ranking signal.
        public var notMine: Double { commits == 0 ? 0 : Double(commits - mine) / Double(commits) }
    }

    public func history(of path: String, root: String) throws -> FileHistory? {
        try writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT h.commits, h.mine, h.lastCommitAt FROM fileHistory h JOIN repo r ON r.id = h.repoId
                WHERE r.root = ? AND h.path = ?
                """, arguments: [root, path])
                .map { FileHistory(commits: $0["commits"], mine: $0["mine"], lastCommitAt: $0["lastCommitAt"]) }
        }
    }

    /// The highest commit count of any file in the repo, for scaling churn to 0–1.
    public func maxCommits(root: String) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT MAX(h.commits) FROM fileHistory h JOIN repo r ON r.id = h.repoId WHERE r.root = ?
                """, arguments: [root]) ?? 0
        }
    }

    /// Subjects of recent commits that touched `path`, newest first. Cheap "why" evidence.
    public func commitSubjects(touching path: String, root: String, limit: Int = 3) throws -> [String] {
        // Commit-to-file links aren't stored; use git for the few lines needed.
        let result = try Shell.run("git", ["-C", root, "log", "--no-merges", "-n", "\(limit)", "--format=%s", "--", path])
        return result.succeeded ? result.text.split(separator: "\n").map(String.init) : []
    }

    func lastHistoryCommit(repoID: Int64) throws -> String? {
        try writer.read { try String.fetchOne($0, sql: "SELECT historyHead FROM repo WHERE id = ?", arguments: [repoID]) }
    }

    func clearHistory(repoID: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM fileHistory WHERE repoId = ?", arguments: [repoID])
            try db.execute(sql: "DELETE FROM commitInfo WHERE repoId = ?", arguments: [repoID])
            try db.execute(sql: "UPDATE repo SET historyHead = NULL WHERE id = ?", arguments: [repoID])
        }
    }
}
