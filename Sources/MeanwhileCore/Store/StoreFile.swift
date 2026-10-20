import Foundation
import GRDB

/// Opens an on-disk store the same way for all three databases: a private folder, one
/// process at a time through the schema check, a backup before any schema upgrade, and
/// files only the user can read.
///
/// The app (`meanwhile run`) and the worker (`meanwhile work`) can open the same file at
/// nearly the same moment. GRDB runs each migration in its own transaction but checks which
/// are pending outside them, so two processes could both try the same migration. A `flock`
/// on `<name>.lock` beside the database serializes the check, the backup and the migration.
enum StoreFile {
    /// How many backups to keep per database.
    static let backupsKept = 2
    /// How long a statement waits for another process's lock before failing.
    static let busyTimeout: TimeInterval = 5

    /// Opens the database at `path`, backing it up first if it has unapplied migrations.
    /// `upTo` stops the migration early (tests make old-schema files with it).
    static func open(path: String, migrator: DatabaseMigrator, upTo target: String? = nil) throws -> DatabasePool {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return try withLock(path + ".lock") {
            // Wait for the other process instead of failing at once: the last connection to
            // close checkpoints the WAL under an exclusive lock, and both write.
            var configuration = Configuration()
            configuration.busyMode = .timeout(busyTimeout)
            let writer = try DatabasePool(path: path, configuration: configuration)
            try backUpIfUpgrading(writer, path: path, migrator: migrator, upTo: target)
            if let target {
                try migrator.migrate(writer, upTo: target)
            } else {
                try migrator.migrate(writer)
            }
            // SQLite creates the database, WAL and shared-memory files with the umask. They exist
            // once the migration has written, so tighten them now.
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + suffix)
            }
            return writer
        }
    }

    /// Backups of the database at `path`, newest first.
    static func backups(of path: String) -> [URL] {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".bak-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let found: [(url: URL, modified: Date)] = names
            .filter { $0.hasPrefix(prefix) && !$0.hasSuffix(".tmp") }
            .map { name in
                let backup = directory.appendingPathComponent(name)
                let values = try? backup.resourceValues(forKeys: [.contentModificationDateKey])
                return (backup, values?.contentModificationDate ?? .distantPast)
            }
        return found
            .sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.url.path > $1.url.path }
            .map(\.url)
    }

    /// Copies the database to `<name>.bak-<last applied migration>` when migrations are
    /// pending on a file that already has some applied. A brand-new file has nothing to keep.
    private static func backUpIfUpgrading(_ writer: DatabasePool, path: String, migrator: DatabaseMigrator,
                                          upTo target: String?) throws {
        let migrations = migrator.migrations
        let wanted = target.flatMap { migrations.firstIndex(of: $0) }.map { Array(migrations[...$0]) } ?? migrations
        let applied = try writer.read { try migrator.appliedMigrations($0) }
        let pending = wanted.contains { !applied.contains($0) }
        guard pending, let last = applied.last else { return }
        let backup = path + ".bak-" + last
        // Written under a temporary name and renamed, so a crash never leaves a half backup
        // under the real name.
        let temporary = backup + ".tmp"
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: temporary + suffix) }
        guard FileManager.default.createFile(atPath: temporary, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary])
        }
        do {
            let destination = try DatabaseQueue(path: temporary)
            try writer.backup(to: destination)
            try destination.close()
            for suffix in ["-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: temporary + suffix) }
            // rename(2) replaces an older backup of the same name in one step.
            guard rename(temporary, backup) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            throw error
        }
        for old in backups(of: path).dropFirst(backupsKept) { try? FileManager.default.removeItem(at: old) }
    }

    /// Runs `body` holding an exclusive `flock` on `lockPath`, which is created 0600 if needed.
    private static func withLock<T>(_ lockPath: String, _ body: () throws -> T) throws -> T {
        let fd = Darwin.open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
