import Foundation
import GRDB

/// How many model calls Meanwhile may make, decided 2026-10-19: per agent turn, at most one
/// live call (while the agent works) and one post-turn call; per day, 20 in total.
/// Every call is logged in library.sqlite, which is also what the limits count.
public struct GenerationBudget: Sendable {
    public enum Kind: String, Sendable {
        /// During a turn, after the first edit.
        case live
        /// After the turn ends.
        case postTurn = "post-turn"
        /// Once per repo when it is turned on.
        case primer
    }

    public var dailyLimit: Int
    public let library: LibraryStore

    public init(library: LibraryStore, dailyLimit: Int = 20) {
        self.library = library
        self.dailyLimit = dailyLimit
    }

    /// Whether a call of `kind` for `session` may run now.
    public func allows(_ kind: Kind, session: String?, now: Date = Date()) throws -> Bool {
        try library.writer.read { db in
            let dayStart = Calendar.current.startOfDay(for: now)
            let today = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM generationCall WHERE calledAt >= ?",
                                         arguments: [dayStart]) ?? 0
            guard today < dailyLimit else { return false }
            guard kind != .primer, let session else { return true }
            // One of each kind per turn: count calls since this session's turn began.
            let turnStart = try Date.fetchOne(db, sql: "SELECT startedAt FROM agentTurn WHERE session = ?",
                                              arguments: [session]) ?? .distantPast
            let thisTurn = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM generationCall WHERE session = ? AND kind = ? AND calledAt >= ?
                """, arguments: [session, kind.rawValue, turnStart]) ?? 0
            return thisTurn == 0
        }
    }

    /// Marks the start of an agent turn, so per-turn limits reset.
    public func turnStarted(session: String, at now: Date = Date()) throws {
        try library.writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO agentTurn (session, startedAt) VALUES (?, ?)",
                           arguments: [session, now])
        }
    }

    /// Logs a call (successful or not); it counts against the limits either way.
    public func record(_ kind: Kind, provider: String, repo: String?, session: String?,
                       succeeded: Bool, duration: TimeInterval, at now: Date = Date()) throws {
        try library.writer.write { db in
            try db.execute(sql: """
                INSERT INTO generationCall (calledAt, kind, provider, repo, session, succeeded, durationMs)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [now, kind.rawValue, provider, repo, session, succeeded, Int(duration * 1000)])
        }
    }

    public func callsToday(now: Date = Date()) throws -> Int {
        try library.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM generationCall WHERE calledAt >= ?",
                             arguments: [Calendar.current.startOfDay(for: now)]) ?? 0
        }
    }
}
