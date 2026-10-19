import Foundation
import Testing
import MeanwhileIPC
@testable import MeanwhileCore

/// Task 2.0: the worker the hook starts, its queue and lock.

/// A throwaway git repo with `files` committed.
func makeGitRepo(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
    for (path, content) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    for arguments in [["init", "-q"], ["add", "-A"],
                      ["-c", "user.email=dev@example.com", "-c", "user.name=Dev", "commit", "-qm", "first"]] {
        let result = try Shell.run("git", ["-C", root.path] + arguments)
        #expect(result.succeeded, "\(arguments): \(result.stderr)")
    }
    return root.resolvingSymlinksInPath()
}

private func lockPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)").path
}

@Test func workerStartsOnTurnsAndEditsOnly() {
    func reason(_ event: String, _ json: String = "{}") -> String? {
        WorkerLaunch.reason(event: event, payload: Data(json.utf8))
    }
    #expect(reason("UserPromptSubmit") == "turn-start")
    #expect(reason("Stop") == "turn-end")
    #expect(reason("PostToolUse", #"{"tool_name":"Edit"}"#) == "edit")
    #expect(reason("PostToolUse", #"{"tool_name":"apply_patch"}"#) == "edit")
    #expect(reason("PostToolUse", #"{"tool_name":"Read"}"#) == nil)
    #expect(reason("PostToolUse", #"{"tool_name":"Bash"}"#) == nil)
    #expect(reason("Notification") == nil)
}

@Test func workerArgumentsCarryTheEvent() {
    let payload = Data(#"{"cwd":"/r","session_id":"s1"}"#.utf8)
    #expect(WorkerLaunch.arguments(reason: "edit", agent: "codex", payload: payload)
        == ["work", "--repo", "/r", "--reason", "edit", "--agent", "codex", "--session", "s1"])
    #expect(WorkerLaunch.arguments(reason: "edit", agent: "codex", payload: Data("{}".utf8)) == nil)
}

@Test func workerRecordsWhatItCanRead() throws {
    let repo = try makeGitRepo(["README.md": "# Hi", "src/a.swift": "let a = 1"])
    defer { try? FileManager.default.removeItem(at: repo) }
    let library = try LibraryStore(path: nil)
    let worker = Worker(library: library, lockPath: lockPath())

    // Started from a subfolder, it still finds the repo root.
    #expect(try worker.submit(.init(directory: repo.appendingPathComponent("src").path, reason: .turnStart)) == 1)
    let seen = try #require(try library.repo(root: repo.path))
    #expect(seen.fileCount == 2 && seen.accessError == nil && seen.state == .unasked)
    #expect(try library.pendingRequestCount() == 0)
}

@Test func unreadableFolderIsRecordedNotFatal() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = try LibraryStore(path: nil)
    try Worker(library: library, lockPath: lockPath()).submit(.init(directory: folder.path, reason: .edit))
    let seen = try #require(try library.repos().first)
    #expect(seen.fileCount == nil && seen.accessError != nil)
}

@Test func busyWorkerLeavesRequestsQueuedForTheLockHolder() throws {
    let repo = try makeGitRepo(["a.md": "a"])
    defer { try? FileManager.default.removeItem(at: repo) }
    let library = try LibraryStore(path: nil)
    let path = lockPath()
    let worker = Worker(library: library, lockPath: path)

    let held = try #require(Worker.tryLock(path))
    #expect(try worker.submit(.init(directory: repo.path, reason: .turnStart)) == 0)
    #expect(try worker.submit(.init(directory: repo.path, reason: .turnEnd)) == 0)
    #expect(try library.pendingRequestCount() == 2)
    Worker.unlock(held)

    #expect(try worker.submit(.init(directory: repo.path, reason: .edit)) == 3)
    #expect(try library.pendingRequestCount() == 0)
}

@Test func repoStateChanges() throws {
    let library = try LibraryStore(path: nil)
    try library.noteRepo(root: "/r")
    try library.setState(.on, root: "/r")
    try library.noteRepo(root: "/r")
    #expect(try library.repo(root: "/r")?.state == .on, "noting again keeps the state")
}
