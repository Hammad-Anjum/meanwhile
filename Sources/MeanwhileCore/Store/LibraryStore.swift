import Foundation
import GRDB
import MeanwhileIPC

/// Per-repo knowledge Meanwhile builds over time: which repos are on, their index, and the
/// question pool (Phase 2). Written by the worker (`meanwhile work`), read by the app.
/// Never pruned by event retention; a repo's rows go when the repo is turned off.
public final class LibraryStore: Sendable {
    let writer: any DatabaseWriter

    /// Opens (or creates) the store at `path`. Pass nil for an in-memory store (tests).
    public init(path: String? = MeanwhilePaths.libraryStore.path) throws {
        if let path {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            writer = try DatabasePool(path: path)
        } else {
            writer = try DatabaseQueue()
        }
        try Self.migrator.migrate(writer)
        if let path {
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + suffix)
            }
        }
    }

    // MARK: Repos

    public struct Repo: Sendable, Equatable {
        public enum State: String, Sendable {
            /// Seen, not asked yet.
            case unasked
            case on
            /// "Not now": ask again next session.
            case later
            case never
        }

        /// This checkout's folder: the repo, or one of its git worktrees.
        public var root: String
        /// The main worktree's folder: the project all of the repo's worktrees share, with one
        /// opt-in, repo card and question pool. Equal to `root` for the main checkout.
        public var project: String
        /// The project's opt-in state, shared by all its worktrees.
        public var state: State
        public var lastIndexedAt: Date?
        public var fileCount: Int?
        /// Why the worker couldn't read the repo, if it couldn't.
        public var accessError: String?
        /// Detected by the worker; the app can't read repos in protected folders itself.
        public var stacks: Set<Stack> = []
        /// When the opt-in card was last shown.
        public var askedAt: Date?

        public var name: String { (root as NSString).lastPathComponent }
        public var isWorktree: Bool { project != root }

        /// Whether the notch should offer to turn codebase questions on: never for an empty
        /// or unreadable repo; "Not now" comes back after a day (decided 2026-10-19).
        public func shouldAsk(now: Date = Date()) -> Bool {
            guard accessError == nil, (fileCount ?? 0) > 0 else { return false }
            switch state {
            case .unasked: return true
            case .later: return askedAt.map { now.timeIntervalSince($0) >= 24 * 3600 } ?? true
            case .on, .never: return false
            }
        }
    }

    /// A checkout row with the project's shared opt-in state and when it was asked.
    private static let repoSelect = """
        SELECT r.*, COALESCE(p.state, r.state) AS sharedState, COALESCE(p.askedAt, r.askedAt) AS sharedAskedAt
        FROM repo r LEFT JOIN repo p ON p.root = r.projectRoot AND p.id != r.id
        """

    public func repo(root: String) throws -> Repo? {
        try writer.read { db in
            try Row.fetchOne(db, sql: Self.repoSelect + " WHERE r.root = ?", arguments: [root]).map(Self.repo)
        }
    }

    /// The project (main worktree) a checkout belongs to; the checkout itself until the
    /// worker has asked git.
    public func projectRoot(of root: String) throws -> String {
        try writer.read {
            try String.fetchOne($0, sql: "SELECT projectRoot FROM repo WHERE root = ?", arguments: [root])
        } ?? root
    }

    /// The known repo containing `directory` (the deepest root that is a prefix of it).
    public func repo(containing directory: String) throws -> Repo? {
        let path = (directory as NSString).standardizingPath
        return try repos()
            .filter { path == $0.root || path.hasPrefix($0.root.hasSuffix("/") ? $0.root : $0.root + "/") }
            .max { $0.root.count < $1.root.count }
    }

    public func recordStacks(_ stacks: Set<Stack>, root: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE repo SET stacks = ? WHERE root = ?",
                           arguments: [stacks.map(\.rawValue).sorted().joined(separator: ","), root])
        }
    }

    /// Records the user's answer to the opt-in card, for the whole project: every worktree
    /// of the repo shares it.
    public func answerOptIn(_ state: Repo.State, root: String, at now: Date = Date()) throws {
        let project = try projectRoot(of: root)
        try noteRepo(root: project)
        try writer.write { db in
            try db.execute(sql: "UPDATE repo SET state = ?, askedAt = ? WHERE root = ?",
                           arguments: [state.rawValue, now, project])
        }
        if state == .never { try purgeKnowledge(root: project) }
    }

    public func repos() throws -> [Repo] {
        try writer.read { db in try Row.fetchAll(db, sql: Self.repoSelect + " ORDER BY r.root").map(Self.repo) }
    }

    /// Records a repo the first time it is seen; leaves an existing row alone.
    @discardableResult
    public func noteRepo(root: String) throws -> Repo {
        try writer.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO repo (root, state) VALUES (?, ?)",
                           arguments: [root, Repo.State.unasked.rawValue])
        }
        return try repo(root: root)!
    }

    public func setState(_ state: Repo.State, root: String) throws {
        let project = try projectRoot(of: root)
        try noteRepo(root: project)
        try writer.write { db in
            try db.execute(sql: "UPDATE repo SET state = ? WHERE root = ?", arguments: [state.rawValue, project])
        }
        if state == .never { try purgeKnowledge(root: project) }
    }

    // MARK: Projects and worktrees

    /// Records that the checkout at `root` is a worktree of `project` (its main worktree),
    /// and folds in anything the checkout learned on its own before (its pool, its answer).
    public func attach(root: String, toProject project: String) throws {
        try noteRepo(root: root)
        guard project != root else {
            try writer.write { try $0.execute(sql: "UPDATE repo SET projectRoot = NULL WHERE root = ?", arguments: [root]) }
            return
        }
        try noteRepo(root: project)
        try writer.write { db in
            try db.execute(sql: "UPDATE repo SET projectRoot = ? WHERE root = ?", arguments: [project, root])
        }
        try merge(root, into: project)
    }

    /// Removes checkouts of `project` that git no longer lists as worktrees, and dead
    /// worktree folders inside the project's folder that were never attached (seen before
    /// projects existed). Their questions move to the project first. Returns the roots removed.
    @discardableResult
    public func pruneCheckouts(ofProject project: String, liveWorktrees: Set<String>,
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws -> [String] {
        let prefix = project.hasSuffix("/") ? project : project + "/"
        let dead = try repos().filter { repo in
            guard repo.root != project, !liveWorktrees.contains(repo.root) else { return false }
            if repo.project == project { return true }
            return !repo.isWorktree && repo.root.hasPrefix(prefix) && !exists(repo.root)
        }
        for repo in dead {
            try merge(repo.root, into: project)
            try writer.write { db in
                try db.execute(sql: "DELETE FROM repo WHERE root = ?", arguments: [repo.root])
                // Questions about files inside the removed folder (asked from the project before
                // edits were kept to their own checkout) have nothing left to ask about.
                if repo.root.hasPrefix(prefix) {
                    let inside = String(repo.root.dropFirst(prefix.count)) + "/"
                    try db.execute(sql: """
                        UPDATE poolQuestion SET status = 'retired'
                        WHERE repoId = (SELECT id FROM repo WHERE root = ?) AND status = 'ready' AND substr(sourcePath, 1, ?) = ?
                        """, arguments: [project, inside.count, inside])
                }
            }
        }
        return dead.map(\.root)
    }

    /// Moves `checkout`'s own questions, card and opt-in answer to `project`. A question whose
    /// source and quote the project already has is retired, not duplicated.
    private func merge(_ checkout: String, into project: String) throws {
        try writer.write { db in
            guard let from = try Row.fetchOne(db, sql: "SELECT * FROM repo WHERE root = ?", arguments: [checkout]),
                  let to = try Row.fetchOne(db, sql: "SELECT * FROM repo WHERE root = ?", arguments: [project]) else { return }
            let fromID: Int64 = from["id"], toID: Int64 = to["id"]
            guard fromID != toID else { return }

            let kept = try Row.fetchAll(db, sql: "SELECT sourcePath, quote FROM poolQuestion WHERE repoId = ?", arguments: [toID])
            var seen = Set(kept.map { ($0["sourcePath"] as String) + "\u{1f}" + QuestionValidator.normalize($0["quote"]) })
            for row in try Row.fetchAll(db, sql: "SELECT id, sourcePath, quote FROM poolQuestion WHERE repoId = ?", arguments: [fromID]) {
                let key = (row["sourcePath"] as String) + "\u{1f}" + QuestionValidator.normalize(row["quote"])
                let duplicate = !seen.insert(key).inserted
                try db.execute(sql: """
                    UPDATE poolQuestion SET repoId = ?, checkout = COALESCE(checkout, ?),
                      status = CASE WHEN ? THEN 'retired' ELSE status END WHERE id = ?
                    """, arguments: [toID, checkout, duplicate, row["id"] as String])
            }

            // An answer given in the worktree stands when the project has none yet.
            let projectState = Repo.State(rawValue: to["state"]) ?? .unasked
            let checkoutState = Repo.State(rawValue: from["state"]) ?? .unasked
            if [.unasked, .later].contains(projectState), [.on, .never].contains(checkoutState) {
                try db.execute(sql: "UPDATE repo SET state = ?, askedAt = ? WHERE id = ?",
                               arguments: [checkoutState.rawValue, from["askedAt"] as Date?, toID])
            }
            if to["primedAt"] as Date? == nil, let primed = from["primedAt"] as Date? {
                try db.execute(sql: "UPDATE repo SET card = ?, primedAt = ? WHERE id = ?",
                               arguments: [from["card"] as String?, primed, toID])
            }
            try db.execute(sql: "UPDATE repo SET card = NULL, primedAt = NULL WHERE id = ?", arguments: [fromID])
        }
    }

    /// "Never" is a privacy boundary: remember the choice, but remove everything learned
    /// from the project and all its worktrees. Shared blobs remain only while another
    /// opted-in repo references them.
    func purgeKnowledge(root: String) throws {
        try writer.write { db in
            let repoIDs = try Int64.fetchAll(db, sql: "SELECT id FROM repo WHERE root = ? OR projectRoot = ?",
                                             arguments: [root, root])
            guard !repoIDs.isEmpty else { return }
            for repoID in repoIDs {
                for table in ["poolQuestion", "fileRank", "fileHistory", "commitInfo", "fileEntry"] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE repoId = ?", arguments: [repoID])
                }
            }

            let orphanSHAs = try String.fetchAll(db, sql: """
                SELECT b.sha FROM blob b LEFT JOIN fileEntry f ON f.sha = b.sha WHERE f.sha IS NULL
                """)
            if !orphanSHAs.isEmpty {
                for sha in orphanSHAs {
                    let chunks = try Row.fetchAll(db, sql: "SELECT id, trail, body FROM docChunk WHERE sha = ?", arguments: [sha])
                    for chunk in chunks {
                        try db.execute(sql: """
                            INSERT INTO docChunkFts(docChunkFts, rowid, trail, body) VALUES('delete', ?, ?, ?)
                            """, arguments: [chunk["id"] as Int64, chunk["trail"] as String, chunk["body"] as String])
                    }
                    try db.execute(sql: "DELETE FROM docMention WHERE chunkId IN (SELECT id FROM docChunk WHERE sha = ?)", arguments: [sha])
                    try db.execute(sql: "DELETE FROM docChunk WHERE sha = ?", arguments: [sha])
                    try db.execute(sql: "DELETE FROM symbolDef WHERE sha = ?", arguments: [sha])
                    try db.execute(sql: "DELETE FROM symbolRef WHERE sha = ?", arguments: [sha])
                    try db.execute(sql: "DELETE FROM blob WHERE sha = ?", arguments: [sha])
                }
            }
            for repoID in repoIDs {
                try db.execute(sql: """
                    UPDATE repo SET head = NULL, statusHash = NULL, historyHead = NULL, lastIndexedAt = NULL,
                      card = NULL, primedAt = NULL, stacks = NULL WHERE id = ?
                    """, arguments: [repoID])
            }
        }
    }

    /// The worker's result from looking at a repo: a file count, or why it couldn't.
    public func recordAccess(root: String, fileCount: Int?, error: String?, at now: Date = Date()) throws {
        try noteRepo(root: root)
        try writer.write { db in
            try db.execute(
                sql: "UPDATE repo SET lastIndexedAt = ?, fileCount = ?, accessError = ? WHERE root = ?",
                arguments: [now, fileCount, error, root])
        }
    }

    // MARK: Index (task 2.3)

    func repoID(root: String) throws -> Int64 {
        try noteRepo(root: root)
        return try writer.read { try Int64.fetchOne($0, sql: "SELECT id FROM repo WHERE root = ?", arguments: [root])! }
    }

    func indexState(repoID: Int64) throws -> (head: String?, status: String)? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT head, statusHash FROM repo WHERE id = ?", arguments: [repoID]),
                  let status = row["statusHash"] as String? else { return nil }
            return (row["head"], status)
        }
    }

    func fileEntries(repoID: Int64) throws -> [String: String] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT path, sha FROM fileEntry WHERE repoId = ?", arguments: [repoID])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["path"], $0["sha"]) })
        }
    }

    func fileCount(repoID: Int64) throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fileEntry WHERE repoId = ?", arguments: [repoID]) ?? 0 }
    }

    func knownBlobs(_ hashes: Set<String>) throws -> Set<String> {
        guard !hashes.isEmpty else { return [] }
        return try writer.read { db in
            var known = Set<String>()
            // SQLite caps bound parameters; ask in chunks.
            let all = Array(hashes)
            for start in stride(from: 0, to: all.count, by: 500) {
                let chunk = Array(all[start..<min(start + 500, all.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                known.formUnion(try String.fetchAll(db, sql: "SELECT sha FROM blob WHERE sha IN (\(marks))",
                                                    arguments: StatementArguments(chunk)))
            }
            return known
        }
    }

    /// The current blob of each path in a repo, for staleness checks and evidence.
    public func blob(of path: String, root: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT f.sha FROM fileEntry f JOIN repo r ON r.id = f.repoId WHERE r.root = ? AND f.path = ?
                """, arguments: [root, path])
        }
    }

    private static func repo(_ row: Row) -> Repo {
        let stacks = (row["stacks"] as String?)?.split(separator: ",").compactMap { Stack(rawValue: String($0)) } ?? []
        let root: String = row["root"]
        // Rows read with `repoSelect` carry the project's shared state; plain rows their own.
        let state: String = row["sharedState"] ?? row["state"]
        return Repo(root: root, project: row["projectRoot"] ?? root, state: Repo.State(rawValue: state) ?? .unasked,
                    lastIndexedAt: row["lastIndexedAt"], fileCount: row["fileCount"], accessError: row["accessError"],
                    stacks: Set(stacks), askedAt: row["sharedAskedAt"] ?? row["askedAt"])
    }

    // MARK: Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-repos") { db in
            try db.create(table: "repo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("root", .text).notNull().unique()
                t.column("state", .text).notNull()
                t.column("lastIndexedAt", .datetime)
                t.column("fileCount", .integer)
                t.column("accessError", .text)
            }
            // Requests from `meanwhile-hook`, processed in order by whichever worker holds the lock.
            try db.create(table: "workRequest") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("directory", .text).notNull()
                t.column("reason", .text).notNull()
                t.column("agent", .text)
                t.column("session", .text)
                t.column("requestedAt", .datetime).notNull()
            }
        }
        // Task 2.1: every model call, for the per-turn and daily budget.
        migrator.registerMigration("v2-budget") { db in
            try db.create(table: "generationCall") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("calledAt", .datetime).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("provider", .text).notNull()
                t.column("repo", .text)
                t.column("session", .text)
                t.column("succeeded", .boolean).notNull()
                t.column("durationMs", .integer).notNull()
            }
            try db.create(table: "agentTurn") { t in
                t.primaryKey("session", .text)
                t.column("startedAt", .datetime).notNull()
            }
        }
        // Task 2.2: opt-in and the stacks the worker detects.
        migrator.registerMigration("v3-opt-in") { db in
            try db.alter(table: "repo") { t in
                t.add(column: "stacks", .text)
                t.add(column: "askedAt", .datetime)
            }
        }
        // Task 2.3: the file map, content-addressed by git blob hash.
        migrator.registerMigration("v4-index") { db in
            try db.alter(table: "repo") { t in
                t.add(column: "head", .text)
                t.add(column: "statusHash", .text)
            }
            // One row per unique file content, shared by every repo and branch that has it.
            try db.create(table: "blob") { t in
                t.primaryKey("sha", .text)
                t.column("size", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("skipReason", .text)
            }
            // Which blob each path is at, per repo, as of the last index.
            try db.create(table: "fileEntry") { t in
                t.column("repoId", .integer).notNull().references("repo", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("sha", .text).notNull().indexed()
                t.primaryKey(["repoId", "path"])
            }
        }
        // Task 2.4: doc chunks with full-text search, and per-file git history.
        migrator.registerMigration("v5-docs-history") { db in
            try db.alter(table: "blob") { t in t.add(column: "chunked", .boolean).notNull().defaults(to: false) }
            try db.alter(table: "repo") { t in t.add(column: "historyHead", .text) }
            try db.create(table: "docChunk") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sha", .text).notNull().indexed()
                t.column("ordinal", .integer).notNull()
                t.column("trail", .text).notNull()
                t.column("body", .text).notNull()
            }
            // External-content FTS5 over docChunk; detail=column keeps it 2–5× smaller.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE docChunkFts USING fts5(
                  trail, body, content='docChunk', content_rowid='id', detail=column)
                """)
            try db.create(table: "docMention") { t in
                t.column("chunkId", .integer).notNull().references("docChunk", onDelete: .cascade)
                t.column("token", .text).notNull().indexed()
                t.primaryKey(["chunkId", "token"])
            }
            try db.create(table: "fileHistory") { t in
                t.column("repoId", .integer).notNull().references("repo", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("commits", .integer).notNull()
                t.column("mine", .integer).notNull()
                t.column("lastCommitAt", .datetime)
                t.primaryKey(["repoId", "path"])
            }
            try db.create(table: "commitInfo") { t in
                t.column("repoId", .integer).notNull().references("repo", onDelete: .cascade)
                t.column("sha", .text).notNull()
                t.column("email", .text).notNull()
                t.column("committedAt", .datetime).notNull()
                t.column("subject", .text).notNull()
                t.primaryKey(["repoId", "sha"])
            }
        }
        // Tasks 2.6–2.7: the question pool and the primer's repo card.
        migrator.registerMigration("v6-pool") { db in
            try db.alter(table: "repo") { t in
                t.add(column: "card", .text)
                t.add(column: "primedAt", .datetime)
            }
            try db.create(table: "poolQuestion") { t in
                t.primaryKey("id", .text)
                t.column("repoId", .integer).notNull().references("repo", onDelete: .cascade).indexed()
                t.column("kind", .text).notNull()
                t.column("topic", .text).notNull()
                t.column("type", .text).notNull()
                t.column("question", .text).notNull()
                t.column("options", .text).notNull()
                t.column("correct", .integer).notNull()
                t.column("explanation", .text).notNull()
                t.column("quote", .text).notNull()
                t.column("sourcePath", .text).notNull()
                // JSON {path: blob}: what the question cites, for staleness.
                t.column("evidence", .text).notNull()
                t.column("score", .integer).notNull()
                t.column("promptVersion", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("status", .text).notNull()
            }
        }
        // Task 2.11: symbols, references and file rank. (Migrations apply in this order.)
        migrator.registerMigration("v7-symbols") { db in
            try db.alter(table: "blob") { t in t.add(column: "symbolized", .boolean).notNull().defaults(to: false) }
            try db.create(table: "symbolDef") { t in
                t.column("sha", .text).notNull().indexed()
                t.column("name", .text).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("line", .integer).notNull()
            }
            try db.create(table: "symbolRef") { t in
                t.column("sha", .text).notNull()
                t.column("name", .text).notNull().indexed()
                t.primaryKey(["sha", "name"])
            }
            try db.create(table: "fileRank") { t in
                t.column("repoId", .integer).notNull().references("repo", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("percentile", .double).notNull()
                t.primaryKey(["repoId", "path"])
            }
        }
        // Worktrees: each checkout keeps its own index; the project (main worktree) row holds
        // the shared opt-in, card and pool. A question remembers the checkout it came from.
        migrator.registerMigration("v8-projects") { db in
            try db.alter(table: "repo") { t in t.add(column: "projectRoot", .text) }
            try db.create(index: "repo_on_projectRoot", on: "repo", columns: ["projectRoot"])
            try db.alter(table: "poolQuestion") { t in t.add(column: "checkout", .text) }
            try db.execute(sql: "UPDATE poolQuestion SET checkout = (SELECT root FROM repo WHERE repo.id = poolQuestion.repoId)")
        }
        return migrator
    }
}
