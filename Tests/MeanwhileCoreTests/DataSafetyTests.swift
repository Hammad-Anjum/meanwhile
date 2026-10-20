import Foundation
import GRDB
import Testing
@testable import MeanwhileCore

/// User data survives upgrades: databases are backed up before a schema change, and the
/// launchd log stays bounded.

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("meanwhile-safety-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func permissions(_ path: String) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
}

/// A library file as an older build left it: migrated up to v7, before worktree projects.
private func oldLibrary(at path: String) throws {
    let pool = try StoreFile.open(path: path, migrator: LibraryStore.migrator, upTo: "v7-symbols")
    try pool.write { try $0.execute(sql: "INSERT INTO repo (root, state) VALUES ('/old/repo', 'on')") }
    try pool.close()
}

@Test func upgradeBacksUpTheOldSchemaAndData() throws {
    let path = try temporaryDirectory().appendingPathComponent("library.sqlite").path
    try oldLibrary(at: path)
    #expect(StoreFile.backups(of: path).isEmpty)  // brand new: nothing to keep

    let library = try LibraryStore(path: path)
    #expect(try library.repo(root: "/old/repo")?.state == .on)

    let backups = StoreFile.backups(of: path)
    #expect(backups.map(\.lastPathComponent) == ["library.sqlite.bak-v7-symbols"])
    let backup = try #require(backups.first).path
    #expect(try permissions(backup) == 0o600)
    #expect(!FileManager.default.fileExists(atPath: backup + ".tmp"))
    let old = try DatabaseQueue(path: backup)
    let (columns, roots, applied) = try old.read { db in
        (try db.columns(in: "repo").map(\.name), try String.fetchAll(db, sql: "SELECT root FROM repo"),
         try LibraryStore.migrator.appliedMigrations(db))
    }
    #expect(!columns.contains("projectRoot"))
    #expect(roots == ["/old/repo"])
    #expect(applied.last == "v7-symbols")
}

@Test func noBackupWhenNothingIsPending() throws {
    let directory = try temporaryDirectory()
    _ = try LibraryStore(path: directory.appendingPathComponent("library.sqlite").path)
    _ = try LibraryStore(path: directory.appendingPathComponent("library.sqlite").path)
    _ = try ReviewStore(path: directory.appendingPathComponent("reviews.sqlite").path)
    _ = try ReviewStore(path: directory.appendingPathComponent("reviews.sqlite").path)
    _ = try EventStore(path: directory.appendingPathComponent("meanwhile.sqlite").path)
    _ = try EventStore(path: directory.appendingPathComponent("meanwhile.sqlite").path)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!names.contains { $0.contains(".bak-") })
}

@Test func keepsTheTwoNewestBackups() throws {
    let path = try temporaryDirectory().appendingPathComponent("reviews.sqlite").path
    for target in ["v1", "v2", "v4-suppressed"] {
        try StoreFile.open(path: path, migrator: ReviewStore.migrator, upTo: target).close()
    }
    _ = try ReviewStore(path: path)
    #expect(StoreFile.backups(of: path).map(\.lastPathComponent)
            == ["reviews.sqlite.bak-v4-suppressed", "reviews.sqlite.bak-v2"])
}

@Test func racingOpensMigrateOnceAndBackUpOnce() async throws {
    let path = try temporaryDirectory().appendingPathComponent("library.sqlite").path
    try oldLibrary(at: path)
    // Separate opens of the lock file conflict even within one process, like app and worker.
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<6 { group.addTask { _ = try LibraryStore(path: path) } }
        try await group.waitForAll()
    }
    #expect(StoreFile.backups(of: path).map(\.lastPathComponent) == ["library.sqlite.bak-v7-symbols"])
    #expect(try LibraryStore(path: path).repo(root: "/old/repo")?.state == .on)
}

// MARK: Log rotation

@Test func smallLogIsLeftAlone() throws {
    let log = try temporaryDirectory().appendingPathComponent("meanwhile.log")
    #expect(try LogRotation.rotateIfNeeded(at: log) == false)  // missing
    try Data("short\n".utf8).write(to: log)
    #expect(try LogRotation.rotateIfNeeded(at: log, limit: 100, keep: 10) == false)
    #expect(try String(contentsOf: log, encoding: .utf8) == "short\n")
    #expect(!FileManager.default.fileExists(atPath: log.path + ".1"))
}

@Test func bigLogKeepsItsTailAndTruncatesInPlace() throws {
    let log = try temporaryDirectory().appendingPathComponent("meanwhile.log")
    let lines = (0..<200).map { "line \($0)\n" }
    try Data(lines.joined().utf8).write(to: log)
    let inode = try #require(FileManager.default.attributesOfItem(atPath: log.path)[.systemFileNumber] as? Int)

    #expect(try LogRotation.rotateIfNeeded(at: log, limit: 1000, keep: 300))

    let kept = try String(contentsOf: URL(fileURLWithPath: log.path + ".1"), encoding: .utf8)
    #expect(kept.utf8.count <= 300 && kept.utf8.count > 250)
    #expect(kept.hasPrefix("line ") && kept.hasSuffix("line 199\n"))
    #expect(lines.joined().hasSuffix(kept))
    #expect(try permissions(log.path + ".1") == 0o600)
    // Same file, now empty: launchd's descriptor still points at it.
    #expect(try FileManager.default.attributesOfItem(atPath: log.path)[.systemFileNumber] as? Int == inode)
    #expect(try Data(contentsOf: log).isEmpty)

    // A second rotation replaces the old tail.
    try Data(String(repeating: "x", count: 1200).utf8 + Data("\nnewest\n".utf8)).write(to: log)
    #expect(try LogRotation.rotateIfNeeded(at: log, limit: 1000, keep: 300))
    #expect(try String(contentsOf: URL(fileURLWithPath: log.path + ".1"), encoding: .utf8) == "newest\n")
}

@Test func appendingWriterContinuesAtTheNewEnd() throws {
    let log = try temporaryDirectory().appendingPathComponent("meanwhile.log")
    let fd = open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    #expect(fd >= 0)
    defer { close(fd) }
    func append(_ text: String) { _ = text.withCString { write(fd, $0, strlen($0)) } }
    for i in 0..<500 { append("before \(i)\n") }

    #expect(try LogRotation.rotateIfNeeded(at: log, limit: 2000, keep: 500))
    append("after\n")

    #expect(try String(contentsOf: log, encoding: .utf8) == "after\n")
    #expect(try String(contentsOf: URL(fileURLWithPath: log.path + ".1"), encoding: .utf8).hasSuffix("before 499\n"))
}
