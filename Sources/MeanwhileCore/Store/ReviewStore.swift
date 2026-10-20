import Foundation
import GRDB
import MeanwhileIPC

/// The user's progress on cards: one review row per card plus a log of every answer.
/// A separate file from the event store, so event retention never deletes progress.
public final class ReviewStore: Sendable {
    private let writer: any DatabaseWriter

    /// Opens (or creates) the store at `path`. Pass nil for an in-memory store (tests).
    public init(path: String? = MeanwhilePaths.reviewStore.path) throws {
        if let path {
            writer = try StoreFile.open(path: path, migrator: Self.migrator)
        } else {
            writer = try DatabaseQueue()
            try Self.migrator.migrate(writer)
        }
    }

    /// Every review, keyed by card id.
    public func reviews() throws -> [String: Review] {
        let rows = try writer.read { try ReviewRecord.fetchAll($0) }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.cardID, $0.review) })
    }

    /// A saved answer, kept so its confidence can still be changed.
    public struct RecordedAnswer: Sendable, Equatable {
        public let answerID: Int64
        public let before: Review
        public let after: Review
        public let correct: Bool
        public let at: Date
    }

    /// Logs an answer and moves the card's spacing.
    /// - Parameter choice: the chosen option, or nil for "I don't know, show me".
    @discardableResult
    public func recordAnswer(cardID: String, choice: Int?, correct: Bool, confidence: Confidence,
                             session: String?, at now: Date = Date()) throws -> RecordedAnswer {
        try writer.write { db in
            let current = try ReviewRecord.fetchOne(db, key: cardID)?.review ?? Review(cardID: cardID)
            let next = Spacing.answered(current, correct: correct, confidence: confidence, at: now)
            try ReviewRecord(next).save(db)
            try db.execute(
                sql: """
                    INSERT INTO answer (cardID, answeredAt, choice, correct, confident, confidence, session)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [cardID, now, choice ?? -1, correct, confidence != .guessed, confidence.rawValue, session])
            return RecordedAnswer(answerID: db.lastInsertedRowID, before: current, after: next, correct: correct, at: now)
        }
    }

    /// Changes a saved answer's confidence (the user picked it after the answer was saved),
    /// re-spacing the card from where it was before that answer.
    @discardableResult
    public func revise(_ answer: RecordedAnswer, confidence: Confidence) throws -> RecordedAnswer {
        try writer.write { db in
            let next = Spacing.answered(answer.before, correct: answer.correct, confidence: confidence, at: answer.at)
            try ReviewRecord(next).save(db)
            try db.execute(sql: "UPDATE answer SET confident = ?, confidence = ? WHERE id = ?",
                           arguments: [confidence != .guessed, confidence.rawValue, answer.answerID])
            return RecordedAnswer(answerID: answer.answerID, before: answer.before, after: next,
                                  correct: answer.correct, at: answer.at)
        }
    }

    /// Removes an answer that the user subsequently reported as an invalid question and
    /// restores spacing exactly to its pre-answer state.
    public func discard(_ answer: RecordedAnswer) throws {
        try writer.write { db in
            try ReviewRecord(answer.before).save(db)
            try db.execute(sql: "DELETE FROM answer WHERE id = ?", arguments: [answer.answerID])
        }
    }

    /// The confidence stored with an answer; for tests and stats.
    public func confidence(ofAnswer id: Int64) throws -> Confidence? {
        try writer.read {
            try String.fetchOne($0, sql: "SELECT confidence FROM answer WHERE id = ?", arguments: [id])
                .flatMap(Confidence.init(rawValue:))
        }
    }

    /// Notes that a card was shown but not answered.
    public func recordShown(cardID: String, at now: Date = Date()) throws {
        try writer.write { db in
            let current = try ReviewRecord.fetchOne(db, key: cardID)?.review ?? Review(cardID: cardID)
            try ReviewRecord(Spacing.shown(current, at: now)).save(db)
        }
    }

    public func answerCount() throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM answer") ?? 0 }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "review") { t in
                t.primaryKey("cardID", .text)
                t.column("step", .integer)
                t.column("dueAt", .datetime).indexed()
                t.column("lastShown", .datetime)
                t.column("timesShown", .integer).notNull()
                t.column("timesCorrect", .integer).notNull()
            }
            // Every answer, for local stats (task 6.1) and a later switch to FSRS.
            try db.create(table: "answer") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("cardID", .text).notNull().indexed()
                t.column("answeredAt", .datetime).notNull()
                t.column("choice", .integer).notNull()
                t.column("correct", .boolean).notNull()
                t.column("confident", .boolean).notNull()
                t.column("session", .text)
            }
        }
        // The notch's three confidence buttons (task 1.6). `choice` is -1 for "show me".
        migrator.registerMigration("v2") { db in
            try db.alter(table: "answer") { t in
                t.add(column: "confidence", .text)
            }
        }
        // Task 2.10: deck cards the user reported as wrong; never shown again.
        migrator.registerMigration("v4-suppressed") { db in
            try db.create(table: "suppressed") { t in
                t.primaryKey("cardID", .text)
                t.column("reportedAt", .datetime).notNull()
            }
        }
        // Task 2.8: every question shown, its outcome and why it was picked, for tuning.
        migrator.registerMigration("v3-shown") { db in
            try db.create(table: "shown") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("cardID", .text).notNull().indexed()
                t.column("deck", .text).notNull()
                t.column("session", .text)
                t.column("shownAt", .datetime).notNull().indexed()
                /// answered · skipped · unanswered (the wait ended) · reported
                t.column("outcome", .text)
                t.column("latencyMs", .integer)
                t.column("why", .text)
                /// JSON of the score terms at the time.
                t.column("terms", .text)
            }
        }
        return migrator
    }

    // MARK: Shown log (task 2.8)

    public enum Outcome: String, Sendable {
        case answered, skipped, unanswered, reported
    }

    /// Logs that a question was shown. Returns the row to finish with `finishShown`.
    @discardableResult
    public func logShown(cardID: String, deck: String, session: String?, why: String?,
                         terms: [String: Double], at now: Date = Date()) throws -> Int64 {
        let termsJSON = String(decoding: try JSONEncoder().encode(terms), as: UTF8.self)
        return try writer.write { db in
            try db.execute(sql: """
                INSERT INTO shown (cardID, deck, session, shownAt, why, terms) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [cardID, deck, session, now, why, termsJSON])
            return db.lastInsertedRowID
        }
    }

    public func finishShown(_ id: Int64, outcome: Outcome, at now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE shown SET outcome = ?,
                  latencyMs = CAST((julianday(?) - julianday(shownAt)) * 86400000 AS INTEGER)
                WHERE id = ? AND outcome IS NULL
                """, arguments: [outcome.rawValue, now, id])
        }
    }

    /// Reporting can happen from the answer feedback screen, after the row was temporarily
    /// marked answered. The report is the final outcome for that single display.
    public func reportShown(_ id: Int64, at now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE shown SET outcome = ?,
                  latencyMs = CAST((julianday(?) - julianday(shownAt)) * 86400000 AS INTEGER)
                WHERE id = ?
                """, arguments: [Outcome.reported.rawValue, now, id])
        }
    }

    /// Answered and skipped counts per deck since `date`.
    public func deckStats(since date: Date) throws -> [String: QuestionSelector.DeckStats] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT deck, SUM(outcome = 'answered') AS answered, SUM(outcome = 'skipped') AS skipped
                FROM shown WHERE shownAt >= ? GROUP BY deck
                """, arguments: [date])
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0["deck"] as String, QuestionSelector.DeckStats(answered: $0["answered"] ?? 0, skipped: $0["skipped"] ?? 0))
            })
        }
    }

    /// Skips per question since `date`.
    public func skips(since date: Date) throws -> [String: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT cardID, COUNT(*) AS n FROM shown WHERE outcome = 'skipped' AND shownAt >= ? GROUP BY cardID
                """, arguments: [date])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["cardID"] as String, $0["n"] as Int) })
        }
    }

    /// "This question is wrong" on a deck card: it never shows again (task 2.10).
    public func suppress(cardID: String, at now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO suppressed (cardID, reportedAt) VALUES (?, ?)", arguments: [cardID, now])
        }
    }

    public func suppressed() throws -> Set<String> {
        try writer.read { Set(try String.fetchAll($0, sql: "SELECT cardID FROM suppressed")) }
    }

    /// Questions shown since `date`, for the daily cap. A reported display still counts.
    public func shownCount(since date: Date) throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM shown WHERE shownAt >= ?", arguments: [date]) ?? 0 }
    }

    /// Share right over the last `count` answers; nil with fewer than `minimum`.
    public func recentAccuracy(last count: Int = 20, minimum: Int = 8) throws -> Double? {
        try writer.read { db in
            let results = try Bool.fetchAll(db, sql: "SELECT correct FROM answer ORDER BY id DESC LIMIT ?", arguments: [count])
            guard results.count >= minimum else { return nil }
            return Double(results.filter { $0 }.count) / Double(results.count)
        }
    }
}

private struct ReviewRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "review"
    var cardID: String
    var step: Int?
    var dueAt: Date?
    var lastShown: Date?
    var timesShown: Int
    var timesCorrect: Int

    init(_ review: Review) {
        cardID = review.cardID
        step = review.step
        dueAt = review.dueAt
        lastShown = review.lastShown
        timesShown = review.timesShown
        timesCorrect = review.timesCorrect
    }

    var review: Review {
        Review(cardID: cardID, step: step, dueAt: dueAt, lastShown: lastShown,
               timesShown: timesShown, timesCorrect: timesCorrect)
    }
}
