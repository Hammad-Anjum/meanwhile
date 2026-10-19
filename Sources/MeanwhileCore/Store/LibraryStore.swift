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

        public var root: String
        public var state: State
        public var lastIndexedAt: Date?
        public var fileCount: Int?
        /// Why the worker couldn't read the repo, if it couldn't.
        public var accessError: String?
    }

    public func repo(root: String) throws -> Repo? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM repo WHERE root = ?", arguments: [root]).map(Self.repo)
        }
    }

    public func repos() throws -> [Repo] {
        try writer.read { db in try Row.fetchAll(db, sql: "SELECT * FROM repo ORDER BY root").map(Self.repo) }
    }

    /// Records a repo the first time it is seen; leaves an existing row alone.
    @discardableResult
    public func noteRepo(root: String) throws -> Repo {
        try writer.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO repo (root, state) VALUES (?, ?)",
                           arguments: [root, Repo.State.unasked.rawValue])
            return try Row.fetchOne(db, sql: "SELECT * FROM repo WHERE root = ?", arguments: [root]).map(Self.repo)!
        }
    }

    public func setState(_ state: Repo.State, root: String) throws {
        try noteRepo(root: root)
        try writer.write { db in
            try db.execute(sql: "UPDATE repo SET state = ? WHERE root = ?", arguments: [state.rawValue, root])
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

    private static func repo(_ row: Row) -> Repo {
        Repo(root: row["root"], state: Repo.State(rawValue: row["state"]) ?? .unasked,
             lastIndexedAt: row["lastIndexedAt"], fileCount: row["fileCount"], accessError: row["accessError"])
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
        return migrator
    }
}
