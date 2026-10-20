import Foundation
import GRDB
import MeanwhileIPC

/// Every hook line Meanwhile receives, raw and adapted, in SQLite. Events contain prompts
/// and code, so the file is private to the user and rows older than `retention` are deleted.
public final class EventStore: Sendable {
    public static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60

    public let retention: TimeInterval
    private let writer: any DatabaseWriter

    /// Opens (or creates) the store at `path`. Pass nil for an in-memory store (tests).
    public init(path: String? = MeanwhilePaths.eventStore.path, retention: TimeInterval = defaultRetention) throws {
        self.retention = retention
        if let path {
            writer = try StoreFile.open(path: path, migrator: Self.migrator)
        } else {
            writer = try DatabaseQueue()
            try Self.migrator.migrate(writer)
        }
    }

    /// Stores one hook line and the events adapted from it, in one transaction.
    /// Returns the events. Lines that adapt to nothing are still kept raw.
    @discardableResult
    public func ingest(_ line: Data, receivedAt: Date = Date()) throws -> [AgentEvent] {
        let events = EventAdapter.events(fromLine: line)
        let encoder = Self.encoder
        try writer.write { db in
            var raw = RawEventRecord(id: nil, receivedAt: receivedAt, line: line)
            try raw.insert(db)
            guard let rawID = raw.id else { return }
            for event in events {
                try EventRecord(
                    id: nil, rawEventId: rawID, agent: event.agent.rawValue, session: event.session,
                    turn: event.turn, subagent: event.subagent, timestamp: event.timestamp, cwd: event.cwd,
                    kind: event.kind.name, body: try encoder.encode(event)
                ).insert(db)
            }
        }
        return events
    }

    /// Events of one session, oldest first.
    public func events(inSession session: String) throws -> [AgentEvent] {
        try fetch(EventRecord.filter(Column("session") == session))
    }

    /// Events at or after `date`, oldest first, optionally limited to one working directory.
    public func events(since date: Date, cwd: String? = nil) throws -> [AgentEvent] {
        var request = EventRecord.filter(Column("timestamp") >= date)
        if let cwd { request = request.filter(Column("cwd") == cwd) }
        return try fetch(request)
    }

    public func rawLineCount() throws -> Int {
        try writer.read { try RawEventRecord.fetchCount($0) }
    }

    /// Deletes raw lines received before `now - retention`, and their events with them.
    @discardableResult
    public func prune(now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-retention)
        return try writer.write { db in
            try RawEventRecord.filter(Column("receivedAt") < cutoff).deleteAll(db)
        }
    }

    private func fetch(_ request: QueryInterfaceRequest<EventRecord>) throws -> [AgentEvent] {
        let records = try writer.read { db in
            try request.order(Column("timestamp"), Column("id")).fetchAll(db)
        }
        let decoder = Self.decoder
        // A row that no longer decodes (schema change) is skipped, not fatal.
        return records.compactMap { try? decoder.decode(AgentEvent.self, from: $0.body) }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "rawEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("receivedAt", .datetime).notNull().indexed()
                t.column("line", .blob).notNull()
            }
            try db.create(table: "event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("rawEvent", onDelete: .cascade).notNull()
                t.column("agent", .text).notNull()
                t.column("session", .text).notNull()
                t.column("turn", .text)
                t.column("subagent", .text)
                t.column("timestamp", .datetime).notNull()
                t.column("cwd", .text).notNull()
                t.column("kind", .text).notNull()
                // The whole AgentEvent as JSON; the columns above are for querying.
                t.column("body", .blob).notNull()
            }
            try db.create(index: "event_session_timestamp", on: "event", columns: ["session", "timestamp"])
            try db.create(index: "event_cwd_timestamp", on: "event", columns: ["cwd", "timestamp"])
            try db.create(index: "event_timestamp", on: "event", columns: ["timestamp"])
        }
        return migrator
    }
}

private struct RawEventRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "rawEvent"
    var id: Int64?
    var receivedAt: Date
    var line: Data

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

private struct EventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "event"
    var id: Int64?
    var rawEventId: Int64
    var agent: String
    var session: String
    var turn: String?
    var subagent: String?
    var timestamp: Date
    var cwd: String
    var kind: String
    var body: Data
}
