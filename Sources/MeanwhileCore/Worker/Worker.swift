import Foundation
import GRDB
import MeanwhileIPC

/// `meanwhile work`: indexes repos and (from task 2.6) generates questions, outside the app.
///
/// Started by `meanwhile-hook`, so it has the agent terminal's file access. Every start
/// records its request first, then takes a lock; whoever holds the lock works through all
/// pending requests, so a request is never lost because another worker was busy.
public struct Worker: Sendable {
    public struct Request: Sendable, Equatable {
        public enum Reason: String, Sendable {
            case turnStart = "turn-start"
            case edit
            case turnEnd = "turn-end"
            case manual
        }

        public var directory: String
        public var reason: Reason
        public var agent: String?
        public var session: String?

        public init(directory: String, reason: Reason, agent: String? = nil, session: String? = nil) {
            self.directory = directory
            self.reason = reason
            self.agent = agent
            self.session = session
        }
    }

    public let library: LibraryStore
    public let lockPath: String

    public init(library: LibraryStore, lockPath: String = MeanwhilePaths.workerLock.path) {
        self.library = library
        self.lockPath = lockPath
    }

    /// Queues `request` and, unless another worker holds the lock, works through the queue.
    /// Returns the number of requests this call processed (0 when another worker is running).
    @discardableResult
    public func submit(_ request: Request) throws -> Int {
        try library.enqueue(request)
        guard let lock = Self.tryLock(lockPath) else { return 0 }
        defer { Self.unlock(lock) }
        var processed = 0
        while let next = try library.dequeue() {
            try process(next)
            processed += 1
        }
        return processed
    }

    /// One request. Task 2.0: find the repo and prove it can be read.
    func process(_ request: Request) throws {
        if request.reason == .turnStart, let session = request.session {
            try GenerationBudget(library: library).turnStarted(session: session)
        }
        let root = StackDetector.repoRoot(for: request.directory)
        let repo = try library.noteRepo(root: root)
        // Repos turned on get the full index; others only what the opt-in card needs.
        if repo.state == .on, let indexed = try? RepoIndexer(library: library).index(root: root) {
            if !indexed.skippedUnchanged {
                try DocIndexer(library: library).process(root: root, newBlobs: indexed.newBlobs)
                try HistoryIndexer(library: library).update(root: root)
            }
            try library.recordStacks(StackDetector.stacks(inRepo: root), root: root)
            try library.writer.write { db in
                try db.execute(sql: "UPDATE repo SET accessError = NULL WHERE root = ?", arguments: [root])
            }
            return
        }
        let listing = try? Shell.run("git", ["-C", root, "ls-files", "-z"], timeout: 30)
        if let listing, listing.succeeded {
            let count = listing.stdout.split(separator: 0).count
            try library.recordAccess(root: root, fileCount: count, error: nil)
            try library.recordStacks(StackDetector.stacks(inRepo: root), root: root)
        } else {
            let reason = listing.map { $0.timedOut ? "git timed out" : $0.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? "git could not start"
            try library.recordAccess(root: root, fileCount: nil, error: reason.isEmpty ? "not readable" : reason)
        }
    }

    // MARK: Lock

    static func tryLock(_ path: String) -> Int32? {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func unlock(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

extension LibraryStore {
    func enqueue(_ request: Worker.Request) throws {
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO workRequest (directory, reason, agent, session, requestedAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [request.directory, request.reason.rawValue, request.agent, request.session, Date()])
        }
    }

    /// The oldest pending request, removed from the queue.
    func dequeue() throws -> Worker.Request? {
        try writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM workRequest ORDER BY id LIMIT 1") else { return nil }
            try db.execute(sql: "DELETE FROM workRequest WHERE id = ?", arguments: [row["id"] as Int64])
            return Worker.Request(directory: row["directory"],
                                  reason: Worker.Request.Reason(rawValue: row["reason"]) ?? .manual,
                                  agent: row["agent"], session: row["session"])
        }
    }

    public func pendingRequestCount() throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM workRequest") ?? 0 }
    }
}
