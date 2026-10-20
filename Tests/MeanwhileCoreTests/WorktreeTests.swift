import Foundation
@testable import MeanwhileCore
import Testing

/// Worktrees of one repo share a project: one opt-in, card and pool; questions show only
/// in checkouts whose files match what they cite.

private func git(_ directory: URL, _ arguments: String...) throws {
    let result = try Shell.run("git", ["-C", directory.path, "-c", "user.email=dev@example.com", "-c", "user.name=Dev"] + arguments)
    #expect(result.succeeded, "\(arguments): \(result.stderr)")
}

/// A repo with a `feature` worktree inside it (like `.claude/worktrees/feature`) whose
/// a.swift differs; README.md is the same in both.
private func repoWithWorktree() throws -> (main: URL, worktree: URL) {
    let main = try makeGitRepo(["README.md": "# App\nShared docs.", "a.swift": "let a = 1\n"])
    let worktree = main.appendingPathComponent(".claude/worktrees/feature")
    try git(main, "worktree", "add", "-q", "-b", "feature", worktree.path)
    try Data("let a = 2\n".utf8).write(to: worktree.appendingPathComponent("a.swift"))
    try git(worktree, "commit", "-qam", "change a")
    return (main, worktree)
}

private func question(_ id: String, root: URL, path: String, blob: String?, quote: String) -> PoolQuestion {
    PoolQuestion(id: id, root: root.path, kind: "post-turn", topic: "Basics", type: "trueFalse",
                 question: "Question \(id)?", options: ["True", "False"], correct: 0, explanation: "Because.",
                 quote: quote, sourcePath: path, evidence: [path: blob ?? "missing"], score: 4,
                 createdAt: Date(), status: .ready)
}

@Test func gitNamesTheProjectFromAnyWorktree() throws {
    let (main, worktree) = try repoWithWorktree()
    defer { try? FileManager.default.removeItem(at: main) }
    // Temporary folders are spelled /var/…, which git reports as /private/var/…: the
    // answer keeps the caller's spelling.
    #expect(main.path.hasPrefix("/var/"))
    let fromWorktree = try #require(Worker.checkouts(of: worktree.path))
    #expect(fromWorktree.project == main.path)
    #expect(fromWorktree.worktrees == [main.path, worktree.path])
    #expect(Worker.checkouts(of: main.path)?.project == main.path)
}

@Test func worktreesShareTheOptInCardAndPool() throws {
    let (main, worktree) = try repoWithWorktree()
    defer { try? FileManager.default.removeItem(at: main) }
    let library = try LibraryStore(path: nil)
    for checkout in [main, worktree] {
        _ = try RepoIndexer(library: library).index(root: checkout.path)
        try library.attach(root: checkout.path, toProject: main.path)
    }

    // Answered in the worktree, it holds for the whole project.
    try library.answerOptIn(.on, root: worktree.path)
    #expect(try library.repo(root: main.path)?.state == .on)
    #expect(try library.repo(root: worktree.path)?.state == .on)
    #expect(try library.repo(root: worktree.path)?.project == main.path)
    try library.setRepoCard("An app.", root: worktree.path)
    #expect(try library.isPrimed(root: main.path))

    // Branch-only code shows only where it is; shared docs show everywhere.
    let mainA = try library.blob(of: "a.swift", root: main.path)
    let featureA = try library.blob(of: "a.swift", root: worktree.path)
    let readme = try library.blob(of: "README.md", root: main.path)
    let featureReadme = try library.blob(of: "README.md", root: worktree.path)
    #expect(mainA != featureA && readme == featureReadme)
    try library.insert(question("main-a", root: main, path: "a.swift", blob: mainA, quote: "let a = 1"))
    try library.insert(question("feature-a", root: worktree, path: "a.swift", blob: featureA, quote: "let a = 2"))
    try library.insert(question("docs", root: main, path: "README.md", blob: readme, quote: "Shared docs."))
    #expect(Set(try library.poolQuestions(visibleIn: main.path).map(\.id)) == ["main-a", "docs"])
    #expect(Set(try library.poolQuestions(visibleIn: worktree.path).map(\.id)) == ["feature-a", "docs"])
    #expect(try library.markStaleQuestions(root: main.path) == 0, "each question holds in some checkout")

    // The worktree is removed: its checkout goes, and so does its branch-only question.
    try git(main, "worktree", "remove", "--force", worktree.path)
    let live = try #require(Worker.checkouts(of: main.path)).worktrees
    #expect(try library.pruneCheckouts(ofProject: main.path, liveWorktrees: live) == [worktree.path])
    #expect(try library.repos().map(\.root) == [main.path])
    #expect(try library.markStaleQuestions(root: main.path) == 1)
    #expect(Set(try library.poolQuestions(root: main.path).map(\.id)) == ["main-a", "docs"])
}

@Test func deadNestedCheckoutsFoldIntoTheProject() throws {
    let library = try LibraryStore(path: nil)
    let project = URL(fileURLWithPath: "/p"), old = URL(fileURLWithPath: "/p/.claude/worktrees/old")
    try library.noteRepo(root: project.path)
    try library.noteRepo(root: "/elsewhere")
    // Seen before projects existed: its own opt-in and questions, one also in the project.
    try library.answerOptIn(.on, root: old.path)
    try library.insert(question("p-same", root: project, path: "a.swift", blob: "x", quote: "let a = 1"))
    try library.insert(question("old-same", root: old, path: "a.swift", blob: "x", quote: "let  a = 1"))
    try library.insert(question("old-new", root: old, path: "b.swift", blob: "y", quote: "let b = 2"))
    // Asked from the project about a file inside the old checkout, before edits stayed in theirs.
    try library.insert(question("leaked", root: project, path: ".claude/worktrees/old/c.swift", blob: "text:1", quote: "let c = 3"))

    let removed = try library.pruneCheckouts(ofProject: project.path, liveWorktrees: [project.path], exists: { _ in false })
    #expect(removed == [old.path], "not /elsewhere: outside the project's folder")
    #expect(try library.repo(root: project.path)?.state == .on)
    let pool = try library.poolQuestions(root: project.path, statuses: [.ready, .retired])
    #expect(Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0.status) })
            == ["p-same": .ready, "old-same": .retired, "old-new": .ready, "leaked": .retired])
    #expect(pool.first { $0.id == "old-new" }?.root == old.path, "remembers where it came from")
}

@Test func editsInANestedCheckoutStayOutOfTheParentsEvidence() throws {
    let (main, worktree) = try repoWithWorktree()
    defer { try? FileManager.default.removeItem(at: main) }
    #expect(EvidenceBuilder.relativePath(worktree.appendingPathComponent("a.swift").path, root: main.path) == nil)
    #expect(EvidenceBuilder.relativePath(main.appendingPathComponent("a.swift").path, root: main.path) == "a.swift")
    #expect(EvidenceBuilder.relativePath(worktree.appendingPathComponent("a.swift").path, root: worktree.path) == "a.swift")
}

@Test func neverInAWorktreePurgesTheWholeProject() throws {
    let (main, worktree) = try repoWithWorktree()
    defer { try? FileManager.default.removeItem(at: main) }
    let library = try LibraryStore(path: nil)
    for checkout in [main, worktree] {
        _ = try RepoIndexer(library: library).index(root: checkout.path)
        try library.attach(root: checkout.path, toProject: main.path)
    }
    try library.insert(question("q", root: main, path: "README.md", blob: "z", quote: "Shared docs."))
    try library.answerOptIn(.never, root: worktree.path)
    #expect(try library.repo(root: main.path)?.state == .never)
    #expect(try library.fileCount(repoID: try library.repoID(root: main.path)) == 0)
    #expect(try library.fileCount(repoID: try library.repoID(root: worktree.path)) == 0)
    #expect(try library.poolQuestions(root: main.path, statuses: [.ready]).isEmpty)
}

@Test func stalenessFollowsTheQuotedFileAndRevertsComeBack() throws {
    let repo = try makeGitRepo(["README.md": "# App\nShared docs.", "a.swift": "let a = 1\n"])
    defer { try? FileManager.default.removeItem(at: repo) }
    let library = try LibraryStore(path: nil)
    _ = try RepoIndexer(library: library).index(root: repo.path)
    let readme = try #require(try library.blob(of: "README.md", root: repo.path))
    let a = try #require(try library.blob(of: "a.swift", root: repo.path))
    // Made before 2026-10-20: quotes README.md but cites every file in its pack.
    try library.insert(PoolQuestion(id: "legacy", root: repo.path, kind: "primer", topic: "Docs", type: "trueFalse",
                                    question: "Are the docs shared?", options: ["True", "False"], correct: 0,
                                    explanation: "They are.", quote: "Shared docs.", sourcePath: "README.md",
                                    evidence: ["README.md": readme, "a.swift": a], score: 4, createdAt: Date(), status: .ready))
    try library.insert(question("code", root: repo, path: "a.swift", blob: a, quote: "let a = 1"))

    // a.swift changes: only the question quoting it goes stale.
    try Data("let a = 2\n".utf8).write(to: repo.appendingPathComponent("a.swift"))
    _ = try RepoIndexer(library: library).index(root: repo.path)
    #expect(try library.markStaleQuestions(root: repo.path) == 1)
    #expect(try library.poolQuestions(root: repo.path).map(\.id) == ["legacy"])

    // Changed back (a branch switched back): the question returns.
    try Data("let a = 1\n".utf8).write(to: repo.appendingPathComponent("a.swift"))
    _ = try RepoIndexer(library: library).index(root: repo.path)
    #expect(try library.markStaleQuestions(root: repo.path) == 0)
    #expect(Set(try library.poolQuestions(root: repo.path).map(\.id)) == ["legacy", "code"])
}
