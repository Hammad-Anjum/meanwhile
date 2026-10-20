import Foundation
import GRDB
import Testing
@testable import MeanwhileCore

/// `meanwhile doctor`: report formatting and the checks that read files, in throwaway folders.

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("doctor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// An executable file standing in for an installed binary.
private func executable(at url: URL) throws -> URL {
    try write("#!/bin/sh\n", to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

// MARK: Report

@Test func reportPrintsOneLinePerCheckAndFixesForProblems() {
    let checks: [Doctor.Check] = [
        .init("a", .ok, "fine", fix: "never shown"),
        .init("b", .warning, "watch out", fix: "do this"),
        .init("c", .failure, "broken", fix: "meanwhile setup"),
    ]
    #expect(Doctor.format(checks) == """
        ✓ fine
        ! watch out
            Fix: do this
        ✗ broken
            Fix: meanwhile setup
        """)
}

@Test func exitCodeIsOneOnlyWhenSomethingFails() {
    #expect(Doctor.exitCode([.init("a", .ok, "x"), .init("b", .warning, "y")]) == 0)
    #expect(Doctor.exitCode([.init("a", .ok, "x"), .init("b", .failure, "y")]) == 1)
    #expect(Doctor.exitCode([]) == 0)
}

@Test func jsonReportCarriesEveryCheck() throws {
    let checks: [Doctor.Check] = [.init("a", .ok, "fine"), .init("b", .failure, "broken", fix: "meanwhile setup")]
    let data = try Doctor.json(checks, version: "9.9.9", date: Date(timeIntervalSince1970: 0))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["version"] as? String == "9.9.9")
    #expect(object["date"] as? String == "1970-01-01T00:00:00Z")
    struct Report: Decodable { let checks: [Doctor.Check] }
    #expect(try JSONDecoder().decode(Report.self, from: data).checks == checks)
}

@Test func macOSBelow14Fails() {
    #expect(Doctor.system(version: .init(majorVersion: 13, minorVersion: 6, patchVersion: 0), architecture: "x86_64").status == .failure)
    let current = Doctor.system(version: .init(majorVersion: 14, minorVersion: 0, patchVersion: 1), architecture: "arm64")
    #expect(current.status == .ok)
    #expect(current.fact == "macOS 14.0.1 on arm64")
}

// MARK: Install

@Test func installedBinariesAndVersion() throws {
    let bin = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: bin) }

    var checks = Doctor.binaries(directory: bin, runningVersion: "1.0", installedVersion: nil, sameBuild: nil)
    #expect(checks.map(\.status) == [.failure])
    #expect(checks[0].fact.contains("meanwhile, meanwhile-hook"))

    _ = try executable(at: bin.appendingPathComponent("meanwhile"))
    _ = try executable(at: bin.appendingPathComponent("meanwhile-hook"))
    try FileManager.default.createDirectory(at: bin.appendingPathComponent("MeanwhileKit_MeanwhileCore.bundle"),
                                            withIntermediateDirectories: true)
    checks = Doctor.binaries(directory: bin, runningVersion: "1.0", installedVersion: "1.0", sameBuild: nil)
    #expect(checks.map(\.status) == [.ok, .ok])
    checks = Doctor.binaries(directory: bin, runningVersion: "1.0", installedVersion: "0.9", sameBuild: nil)
    #expect(checks[1].status == .warning)
    #expect(checks[1].fix == "meanwhile setup")
    checks = Doctor.binaries(directory: bin, runningVersion: "1.0", installedVersion: "1.0", sameBuild: false)
    #expect(checks[1].status == .warning)
    checks = Doctor.binaries(directory: bin, runningVersion: "1.0", installedVersion: nil, sameBuild: nil)
    #expect(checks[1].status == .failure)
}

@Test func findsWhichMeanwhileIsOnPath() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = try executable(at: root.appendingPathComponent("bin/meanwhile"))
    let other = try executable(at: root.appendingPathComponent("other/meanwhile"))

    #expect(Doctor.onPath("/nonexistent", installed: installed).status == .warning)
    #expect(Doctor.onPath("\(root.path)/bin:/usr/bin", installed: installed).status == .ok)
    #expect(Doctor.onPath("\(root.path)/other:\(root.path)/bin", installed: installed).status == .warning)
    #expect(Doctor.which("meanwhile", path: "/nope:\(root.path)/other") == other.path)
}

// MARK: Login item

@Test func readsLaunchctlPrint() {
    let running = Doctor.LaunchStatus(launchctlStatus: 0, output: """
        gui/501/dev.meanwhile.agent = {
        \tactive count = 4
        \tstate = running
        \tpid = 68322
        \tlast exit code = (never exited)
        }
        """)
    #expect(running == .init(loaded: true, running: true, pid: 68322, lastExit: "(never exited)"))
    let stopped = Doctor.LaunchStatus(launchctlStatus: 0, output: "\tstate = not running\n\tlast exit code = 1\n")
    #expect(stopped == .init(loaded: true, running: false, pid: nil, lastExit: "1"))
    let missing = Doctor.LaunchStatus(launchctlStatus: 113, output: "Could not find service")
    #expect(!missing.loaded && !missing.running)
}

@Test func loginItemChecksThePlistAndLaunchd() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let program = try executable(at: home.appendingPathComponent("bin/meanwhile"))
    let agent = LaunchAgent(home: home, executable: program.path)

    let absent = Doctor.loginItem(plist: agent.plistURL, launch: .init(loaded: false, running: false), uid: 501)
    #expect(absent.map(\.status) == [.failure])
    #expect(absent[0].fix == "meanwhile setup")

    try write(String(decoding: try agent.plist(), as: UTF8.self), to: agent.plistURL)
    let unloaded = Doctor.loginItem(plist: agent.plistURL, launch: .init(loaded: false, running: false), uid: 501)
    #expect(unloaded.map(\.status) == [.ok, .failure])
    #expect(unloaded[1].fix?.hasPrefix("launchctl bootstrap gui/501 ") == true)

    let stopped = Doctor.loginItem(plist: agent.plistURL, launch: .init(loaded: true, running: false), uid: 501)
    #expect(stopped[1].fix == "launchctl kickstart gui/501/dev.meanwhile.agent")
    let running = Doctor.loginItem(plist: agent.plistURL, launch: .init(loaded: true, running: true, pid: 7), uid: 501)
    #expect(running.map(\.status) == [.ok, .ok])

    let gone = LaunchAgent(home: home, executable: "/nonexistent/meanwhile")
    try write(String(decoding: try gone.plist(), as: UTF8.self), to: gone.plistURL)
    #expect(Doctor.loginItem(plist: gone.plistURL, launch: .init(loaded: true, running: true), uid: 501)[0].status == .failure)
}

// MARK: Socket and spool

@Test func countsSpooledEvents() throws {
    let spool = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: spool) }
    #expect(Doctor.spoolBacklog(directory: spool) == 0)
    try write("{}\n{}\n", to: spool.appendingPathComponent("events.ndjson"))
    try write("{}\n", to: spool.appendingPathComponent("draining-1.ndjson"))
    try write("", to: spool.appendingPathComponent(".append-lock"))
    #expect(Doctor.spoolBacklog(directory: spool) == 3)
    #expect(Doctor.spool(backlog: 3, appAnswers: false).status == .warning)
    #expect(Doctor.spool(backlog: 0, appAnswers: true).status == .ok)
    #expect(Doctor.socket(path: "/nonexistent.sock", answers: false).status == .failure)
}

// MARK: Hooks

@Test func findsMeanwhileHooksWithoutChangingTheFile() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let hook = try executable(at: home.appendingPathComponent("Application Support/bin/meanwhile-hook"))
    let installer = HookInstaller(home: home, hookPath: hook.path)

    // Not installed at all.
    #expect(Doctor.hooks(.claude, scan: Doctor.scanHooks(.claude, home: home)).status == .ok)

    // Installed, no hooks.
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    var check = Doctor.hooks(.claude, scan: Doctor.scanHooks(.claude, home: home))
    #expect(check.status == .failure)
    #expect(check.fix == "meanwhile setup --agents claude")

    // Set up by `meanwhile setup`.
    try installer.apply(try installer.installPlan(for: .claude))
    let before = try String(contentsOf: installer.file(for: .claude), encoding: .utf8)
    let scan = Doctor.scanHooks(.claude, home: home)
    #expect(scan.missing.isEmpty)
    #expect(scan.commands == [hook.path])
    #expect(Doctor.hooks(.claude, scan: scan).status == .ok)
    #expect(try String(contentsOf: installer.file(for: .claude), encoding: .utf8) == before)

    // An event lost, then the hook binary gone.
    var object = try #require(try JSONSerialization.jsonObject(with: Data(before.utf8)) as? [String: Any])
    var hooks = try #require(object["hooks"] as? [String: Any])
    hooks["Stop"] = nil
    object["hooks"] = hooks
    try JSONSerialization.data(withJSONObject: object).write(to: installer.file(for: .claude))
    check = Doctor.hooks(.claude, scan: Doctor.scanHooks(.claude, home: home))
    #expect(check.status == .warning)
    #expect(check.fact.contains("Stop"))
    try FileManager.default.removeItem(at: hook)
    #expect(Doctor.hooks(.claude, scan: Doctor.scanHooks(.claude, home: home)).status == .failure)

    // Not JSON.
    try write("{ nope", to: installer.file(for: .claude))
    let broken = Doctor.scanHooks(.claude, home: home)
    #expect(broken.unreadable)
    #expect(Doctor.hooks(.claude, scan: broken).status == .failure)
}

@Test func hookCommandExecutable() {
    #expect(Doctor.executable(of: "\"/Users/a b/meanwhile-hook\" claude Stop") == "/Users/a b/meanwhile-hook")
    #expect(Doctor.executable(of: "/usr/local/bin/meanwhile-hook codex Stop") == "/usr/local/bin/meanwhile-hook")
}

// MARK: Provider

@Test func providerLoginFromTheCLIsOwnStatus() {
    let codex = Doctor.providerLogin("codex", status: 0, output: "Logged in using ChatGPT\n")
    #expect(codex.status == .ok)
    #expect(codex.fact == "codex is logged in: Logged in using ChatGPT")

    let claude = Doctor.providerLogin("claude", status: 1, output: """
        Login: Expired — log in again
        Email: someone@example.com
        """)
    #expect(claude.status == .failure)
    #expect(claude.fix == "claude auth login")
    #expect(!claude.fact.contains("@"))
    #expect(Doctor.loginStatusCommand(for: "claude") == ["auth", "status", "--text"])
    #expect(Doctor.loginStatusCommand(for: "codex") == ["login", "status"])
    #expect(Doctor.providerCLI("codex", path: nil).status == .failure)
}

// MARK: Databases

@Test func databaseMigrationsComparedReadOnly() throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("library.sqlite")
    #expect(Doctor.database(Doctor.inspectDatabase(url), registered: ["v1"]).status == .warning)

    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v1'), ('v2')")
    }
    try queue.close()

    let info = Doctor.inspectDatabase(url)
    #expect(info.applied.sorted() == ["v1", "v2"])
    #expect(info.size > 0)
    #expect(Doctor.database(info, registered: ["v1", "v2"]).status == .ok)
    let pending = Doctor.database(info, registered: ["v1", "v2", "v3"])
    #expect(pending.status == .warning)
    #expect(pending.fact.contains("v3"))
    #expect(Doctor.database(info, registered: ["v1"]).status == .failure)
    #expect(Doctor.database(info, registered: nil).status == .ok)

    try write("not a database", to: folder.appendingPathComponent("bad.sqlite"))
    #expect(Doctor.database(Doctor.inspectDatabase(folder.appendingPathComponent("bad.sqlite")), registered: nil).status == .failure)
}

@Test func registeredMigrationsComeFromEachStore() {
    let registered = Doctor.registeredMigrations()
    #expect(registered["meanwhile.sqlite"]?.isEmpty == false)
    #expect(registered["reviews.sqlite"]?.isEmpty == false)
    #expect(registered["library.sqlite"]?.contains("v1-repos") == true)
}

@Test func librarySummaryCountsProjectsAndCalls() throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("library.sqlite")
    let library = try LibraryStore(path: url.path)
    try library.setState(.on, root: "/repos/a")
    try library.noteRepo(root: "/repos/b")
    try library.attach(root: "/repos/a-worktree", toProject: "/repos/a")
    try GenerationBudget(library: library).record(.live, provider: "codex", repo: "/repos/a", session: "s",
                                                  succeeded: true, duration: 1)

    let summary = try Doctor.librarySummary(url)
    #expect(summary == .init(projects: 2, on: 1, callsToday: 1))
    #expect(Doctor.repos(summary).fact == "2 repos, 1 with codebase questions on")
    #expect(Doctor.budget(callsToday: 20).status == .warning)
    #expect(Doctor.budget(callsToday: 3).fact == "Model calls today: 3 of 20")
}

// MARK: Config

@Test func configParseIsReported() throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("config.toml")

    #expect(Doctor.config(url).status == .ok)

    try write("questions_per_round = 5\nround_interval = \"90s\"\n", to: url)
    let good = Doctor.config(url)
    #expect(good.status == .ok)
    #expect(good.fact.contains("questions_per_round = 5, round_interval = 90s"))

    try write("questions_per_round = 99\ncolour = \"blue\"\n", to: url)
    let bad = Doctor.config(url)
    #expect(bad.status == .warning)
    #expect(bad.fact.contains("questions_per_round must be"))
    #expect(bad.fact.contains("No setting called colour"))
    #expect(bad.fact.contains("questions_per_round = 3"))
    #expect(bad.fix == "meanwhile config questions_per_round <value>")
}

@Test func logSize() throws {
    let folder = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("meanwhile.log")
    #expect(Doctor.log(url).fact.hasPrefix("No log yet"))
    try write("hello\n", to: url)
    #expect(Doctor.log(url).status == .ok)
}

@Test func codexTrustIsReportedFromCodexOwnRecord() {
    #expect(Doctor.codexTrust(.noHooks) == nil)
    #expect(Doctor.codexTrust(.trusted)?.status == .ok)
    let untrusted = Doctor.codexTrust(.untrusted(["stop", "user_prompt_submit"]))
    #expect(untrusted?.status == .failure)
    #expect(untrusted?.fact.contains("stop, user_prompt_submit") == true)
    #expect(untrusted?.fix?.contains("/hooks") == true)
}
