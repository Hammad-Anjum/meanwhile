import Foundation
import Testing
@testable import MeanwhileCore

/// Task 2.4: doc chunks with full-text search and mentions, and per-file git history.

@Test func chunksFollowHeadings() {
    let text = """
    Intro before any heading.
    # Architecture
    Overview.
    ## Storage
    Events go to SQLite.
    ```sh
    # not a heading inside a fence
    ```
    ## IPC
    A Unix socket.
    # Usage
    Run it.
    """
    let chunks = DocIndexer.chunks(text, title: "docs/a.md")
    #expect(chunks.map(\.trail) == ["docs/a.md", "Architecture", "Architecture › Storage", "Architecture › IPC", "Usage"])
    #expect(chunks[2].body.contains("# not a heading inside a fence"))
}

@Test func longSectionsAreSplit() {
    let paragraph = String(repeating: "word ", count: 100)
    let text = "# Big\n" + Array(repeating: paragraph, count: 10).joined(separator: "\n\n")
    let chunks = DocIndexer.chunks(text, title: "t", maxCharacters: 1_000)
    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.trail == "Big" && $0.body.count <= 1_000 })
}

@Test func mentionsFindPathsAndIdentifiers() {
    let tokens = DocIndexer.mentions(in: "See `EventServer` in Sources/MeanwhileCore/EventServer.swift and README.md, not v1.2.")
    #expect(tokens.isSuperset(of: ["EventServer", "Sources/MeanwhileCore/EventServer.swift", "EventServer.swift", "README.md"]))
    #expect(!tokens.contains("v1.2"))
}

@Test func lfsPointersAndLongLinesAreSkipped() {
    #expect(DocIndexer.isUnindexable("version https://git-lfs.github.com/spec/v1\noid sha256:abc"))
    #expect(DocIndexer.isUnindexable("ok\n" + String(repeating: "x", count: 5000)))
    #expect(!DocIndexer.isUnindexable("# Fine\nNormal text."))
}

private func indexRepo(_ repo: URL, _ library: LibraryStore) throws {
    let indexed = try RepoIndexer(library: library).index(root: repo.path)
    try DocIndexer(library: library).process(root: repo.path, newBlobs: indexed.newBlobs)
}

@Test func docsAreFoundByMentionAndSearch() throws {
    let repo = try makeGitRepo([
        "docs/design.md": "# Design\n## Events\nThe `EventServer` in Sources/App.swift listens on a Unix socket.\n## Decks\nCards come from JSON packs.",
        "Sources/App.swift": "let server = 1",
    ])
    defer { try? FileManager.default.removeItem(at: repo) }
    let library = try LibraryStore(path: nil)
    try indexRepo(repo, library)

    let mentioning = try library.docChunks(mentioning: ["Sources/App.swift"], root: repo.path)
    #expect(mentioning.map(\.trail) == ["Design › Events"])
    #expect(mentioning.first?.path == "docs/design.md")

    let search = try library.searchDocs("where do the cards come from", root: repo.path)
    #expect(search.first?.trail == "Design › Decks")

    // Indexing again adds nothing: the blob is already chunked.
    #expect(try DocIndexer(library: library).process(root: repo.path, newBlobs: try library.knownBlobs(["x"]).sorted()) == 0)
    #expect(try library.docChunkCount(root: repo.path) == 2)
}

@Test func uncommittedDocIsReadFromDisk() throws {
    let repo = try makeGitRepo(["README.md": "# Old"])
    defer { try? FileManager.default.removeItem(at: repo) }
    let library = try LibraryStore(path: nil)
    try indexRepo(repo, library)
    try Data("# New\nMentions `Widget` now.".utf8).write(to: repo.appendingPathComponent("README.md"))
    try indexRepo(repo, library)
    #expect(try library.docChunks(mentioning: ["Widget"], root: repo.path).first?.trail == "New")
}

@Test func historyCountsChurnAndWhoWroteIt() throws {
    let repo = try makeGitRepo(["a.swift": "1", "b.swift": "1"])  // committed by dev@example.com
    defer { try? FileManager.default.removeItem(at: repo) }
    _ = try Shell.run("git", ["-C", repo.path, "config", "user.email", "dev@example.com"])
    func commit(_ file: String, _ content: String, as email: String, _ message: String) throws {
        try Data(content.utf8).write(to: repo.appendingPathComponent(file))
        let result = try Shell.run("git", ["-C", repo.path, "-c", "user.email=\(email)", "-c", "user.name=X",
                                           "commit", "-qam", message])
        #expect(result.succeeded, "\(result.stderr)")
    }
    try commit("a.swift", "2", as: "agent@example.com", "Rate limit the API")
    try commit("a.swift", "3", as: "agent@example.com", "Retry on 429")

    let library = try LibraryStore(path: nil)
    let indexer = HistoryIndexer(library: library)
    #expect(try indexer.update(root: repo.path) == 3)
    let a = try #require(try library.history(of: "a.swift", root: repo.path))
    #expect(a.commits == 3 && a.mine == 1)
    #expect(abs(a.notMine - 2.0 / 3.0) < 0.001)
    #expect(try library.history(of: "b.swift", root: repo.path)?.notMine == 0)
    #expect(try library.maxCommits(root: repo.path) == 3)

    // Only new commits on the next pass.
    try commit("b.swift", "2", as: "dev@example.com", "Tidy")
    #expect(try indexer.update(root: repo.path) == 1)
    #expect(try indexer.update(root: repo.path) == 0)
    #expect(try library.history(of: "b.swift", root: repo.path)?.commits == 2)
    #expect(try library.commitSubjects(touching: "a.swift", root: repo.path) == ["Retry on 429", "Rate limit the API", "first"])
}

@Test func emptyRepoHasNoHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Shell.run("git", ["-C", root.path, "init", "-q"])
    #expect(try HistoryIndexer(library: try LibraryStore(path: nil)).update(root: root.path) == 0)
}
