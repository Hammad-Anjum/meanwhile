import Foundation
import GRDB
import Testing
@testable import MeanwhileCore

/// Task 2.3: the file map, by git blob hash, kept current without rescans.

private func git(_ repo: URL, _ arguments: String...) throws -> String {
    let result = try Shell.run("git", ["-C", repo.path, "-c", "user.email=dev@example.com", "-c", "user.name=Dev"] + arguments)
    #expect(result.succeeded, "\(arguments): \(result.stderr)")
    return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func write(_ repo: URL, _ path: String, _ content: String) throws {
    let url = repo.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
}

@Test func indexesTrackedFilesWithExclusions() throws {
    let big = String(repeating: "x", count: 400 * 1024)
    let repo = try makeGitRepo([
        "README.md": "# Repo", "Sources/App.swift": "let a = 1", "docs/design.md": "## Why",
        "node_modules/lib/index.js": "x", "package-lock.json": "{}", "web/app.min.js": "x",
        "Assets/logo.png": "png", "data/huge.json": big,
    ])
    defer { try? FileManager.default.removeItem(at: repo) }
    let library = try LibraryStore(path: nil)
    let result = try RepoIndexer(library: library).index(root: repo.path)

    let entries = try library.fileEntries(repoID: try library.repoID(root: repo.path))
    #expect(Set(entries.keys) == ["README.md", "Sources/App.swift", "docs/design.md", "Assets/logo.png", "data/huge.json"])
    #expect(result.added == 5 && result.newBlobs.count == 5)
    try library.writer.read { db in
        let skips = try Row.fetchAll(db, sql: "SELECT f.path, b.kind, b.skipReason FROM fileEntry f JOIN blob b ON b.sha = f.sha")
            .reduce(into: [String: (String, String?)]()) { $0[$1["path"]] = ($1["kind"], $1["skipReason"]) }
        #expect(skips["Assets/logo.png"]?.1 == "binary")
        #expect(skips["data/huge.json"]?.1 == "too large")
        #expect(skips["README.md"]?.0 == "doc" && skips["Sources/App.swift"]?.0 == "code")
    }
    // The blob hash is git's own.
    #expect(try library.blob(of: "Sources/App.swift", root: repo.path) == (try git(repo, "rev-parse", "HEAD:Sources/App.swift")))
}

@Test func unchangedRepoIsSkipped() throws {
    let repo = try makeGitRepo(["a.swift": "let a = 1"])
    defer { try? FileManager.default.removeItem(at: repo) }
    let indexer = RepoIndexer(library: try LibraryStore(path: nil))
    #expect(try !indexer.index(root: repo.path).skippedUnchanged)
    let again = try indexer.index(root: repo.path)
    #expect(again.skippedUnchanged && again.files == 1)
}

@Test func workingTreeChangesAreSeen() throws {
    let repo = try makeGitRepo(["a.swift": "let a = 1", "b.swift": "let b = 2", "README.md": "# R"])
    defer { try? FileManager.default.removeItem(at: repo) }
    let library = try LibraryStore(path: nil)
    let indexer = RepoIndexer(library: library)
    try indexer.index(root: repo.path)

    try write(repo, "a.swift", "let a = 10")          // modified, not committed
    try FileManager.default.removeItem(at: repo.appendingPathComponent("b.swift"))
    try write(repo, "docs/notes.md", "# Notes")       // untracked doc: indexed
    try write(repo, "scratch.swift", "let s = 0")     // untracked code: not indexed
    let result = try indexer.index(root: repo.path)

    #expect(result.changed == 1 && result.removed == 1 && result.added == 1)
    #expect(try library.blob(of: "a.swift", root: repo.path) == (try git(repo, "hash-object", "a.swift")))
    #expect(try library.blob(of: "docs/notes.md", root: repo.path) != nil)
    #expect(try library.blob(of: "scratch.swift", root: repo.path) == nil)
    #expect(try library.blob(of: "b.swift", root: repo.path) == nil)
}

@Test func symlinkedDocsAreNeverIndexed() throws {
    let repo = try makeGitRepo(["README.md": "# Safe"])
    defer { try? FileManager.default.removeItem(at: repo) }
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString).md")
    try Data("external secret".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("leak.md"), withDestinationURL: outside)
    let library = try LibraryStore(path: nil)
    _ = try RepoIndexer(library: library).index(root: repo.path)
    #expect(try library.blob(of: "leak.md", root: repo.path) == nil)
}

@Test func neverOptInPurgesIndexedKnowledge() throws {
    let repo = try makeGitRepo(["README.md": "# Private\nA retained design secret.", "a.swift": "let secret = 1"])
    defer { try? FileManager.default.removeItem(at: repo) }
    let library = try LibraryStore(path: nil)
    let indexed = try RepoIndexer(library: library).index(root: repo.path)
    try DocIndexer(library: library).process(root: repo.path, newBlobs: indexed.newBlobs)
    #expect(try library.fileCount(repoID: try library.repoID(root: repo.path)) == 2)
    #expect(!(try library.searchDocs("retained design", root: repo.path)).isEmpty)

    try library.answerOptIn(.never, root: repo.path)
    #expect(try library.repo(root: repo.path)?.state == .never)
    #expect(try library.fileCount(repoID: try library.repoID(root: repo.path)) == 0)
    #expect((try library.searchDocs("retained design", root: repo.path)).isEmpty)
}

@Test func switchingBackToABranchProcessesNothingNew() throws {
    let repo = try makeGitRepo(["a.swift": "let a = 1"])
    defer { try? FileManager.default.removeItem(at: repo) }
    let indexer = RepoIndexer(library: try LibraryStore(path: nil))
    try indexer.index(root: repo.path)
    let main = try git(repo, "rev-parse", "--abbrev-ref", "HEAD")

    _ = try git(repo, "checkout", "-qb", "feature")
    try write(repo, "a.swift", "let a = 2")
    _ = try git(repo, "commit", "-qam", "change")
    #expect(try indexer.index(root: repo.path).newBlobs.count == 1)

    _ = try git(repo, "checkout", "-q", main)
    let back = try indexer.index(root: repo.path)
    #expect(back.changed == 1 && back.newBlobs.isEmpty, "the old blob is already known")
}

@Test func statusParsingHandlesRenamesAndUntracked() {
    let raw = "R  new.swift\0old.swift\0 M changed.swift\0?? fresh.md\0 D gone.swift\0"
    let (modified, untracked, deleted) = RepoIndexer.parseStatus(Data(raw.utf8))
    #expect(modified == ["new.swift", "changed.swift"])
    #expect(untracked == ["fresh.md"])
    #expect(deleted == ["gone.swift"])
}

@Test func onlyReposTurnedOnGetTheFullIndex() throws {
    let repo = try makeGitRepo(["a.swift": "let a = 1"])
    defer { try? FileManager.default.removeItem(at: repo) }
    let library = try LibraryStore(path: nil)
    let lock = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)").path
    let worker = Worker(library: library, lockPath: lock)

    try worker.submit(.init(directory: repo.path, reason: .turnStart))
    #expect(try library.fileCount(repoID: try library.repoID(root: repo.path)) == 0, "not on: count only")

    try library.setState(.on, root: repo.path)
    try worker.submit(.init(directory: repo.path, reason: .turnEnd))
    #expect(try library.fileCount(repoID: try library.repoID(root: repo.path)) == 1)
}
