import Foundation
import Testing
@testable import MeanwhileCore

/// Task 2.2: when to offer codebase questions for a repo, and repos the app can't read.

private func repo(_ state: LibraryStore.Repo.State, files: Int? = 10, error: String? = nil,
                  askedAt: Date? = nil) -> LibraryStore.Repo {
    LibraryStore.Repo(root: "/r", project: "/r", state: state, fileCount: files, accessError: error, askedAt: askedAt)
}

@Test func whenToOfferCodebaseQuestions() {
    let now = Date()
    #expect(repo(.unasked).shouldAsk(now: now))
    #expect(!repo(.unasked, files: 0).shouldAsk(now: now), "empty repo")
    #expect(!repo(.unasked, files: nil).shouldAsk(now: now), "not read yet")
    #expect(!repo(.unasked, error: "Operation not permitted").shouldAsk(now: now), "unreadable")
    #expect(!repo(.later, askedAt: now.addingTimeInterval(-3600)).shouldAsk(now: now), "not now: same day")
    #expect(repo(.later, askedAt: now.addingTimeInterval(-25 * 3600)).shouldAsk(now: now), "not now: next day")
    #expect(!repo(.on).shouldAsk(now: now))
    #expect(!repo(.never).shouldAsk(now: now))
}

@Test func repoContainingFindsTheDeepestRoot() throws {
    let library = try LibraryStore(path: nil)
    try library.noteRepo(root: "/work/mono")
    try library.noteRepo(root: "/work/mono/vendor/lib")
    try library.noteRepo(root: "/work/monolith")
    #expect(try library.repo(containing: "/work/mono/src/app")?.root == "/work/mono")
    #expect(try library.repo(containing: "/work/mono/vendor/lib/x")?.root == "/work/mono/vendor/lib")
    #expect(try library.repo(containing: "/work/monolith")?.root == "/work/monolith", "not /work/mono")
    #expect(try library.repo(containing: "/elsewhere") == nil)
}

@Test func optInAnswersAreRecorded() throws {
    let library = try LibraryStore(path: nil)
    let now = Date()
    try library.answerOptIn(.later, root: "/r", at: now)
    let saved = try #require(try library.repo(root: "/r"))
    #expect(saved.state == .later && saved.askedAt != nil)
    try library.answerOptIn(.on, root: "/r", at: now)
    #expect(try library.repo(root: "/r")?.state == .on)
}

@Test func workerRecordsStacksForTheApp() throws {
    let repo = try makeGitRepo(["Package.swift": "// swift-tools-version: 6.0", "web/package.json": #"{"dependencies":{"react":"19"}}"#])
    defer { try? FileManager.default.removeItem(at: repo) }
    let library = try LibraryStore(path: nil)
    let lock = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)").path
    try Worker(library: library, lockPath: lock).submit(.init(directory: repo.path, reason: .turnStart))
    #expect(try library.repo(root: repo.path)?.stacks == [.swift, .javascript, .react])
}

@Test func knownStacksOverrideDetection() {
    let decks = PackLibrary.bundled().library
    // A folder the app can't (or doesn't) read, with stacks the worker found.
    let ids = decks.packs(forDirectory: "/nonexistent", disabled: [], knownStacks: [.python]).map(\.id)
    #expect(ids.contains("python") && !ids.contains("swift-macos"))
}
