import Foundation
import Testing
@testable import MeanwhileCore

/// Task 1.7: hook installation and the launch agent, in a throwaway home directory.

private func temporaryHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let hookPath = "/Users/dev/Library/Application Support/Meanwhile/bin/meanwhile-hook"

private func json(_ url: URL) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// A user's real-looking settings: other keys, and a hook of their own on Stop.
private let existingClaudeSettings = """
{
  "model": "opus",
  "permissions": { "allow": ["Bash(git status)"] },
  "hooks": {
    "Stop": [ { "hooks": [ { "type": "command", "command": "say done" } ] } ]
  }
}
"""

@Test func installIntoAFreshHome() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = HookInstaller(home: home, hookPath: hookPath)

    let plan = try installer.installPlan(for: .claude)
    #expect(plan.before == nil && plan.added.count == 10)
    #expect(try installer.apply(plan) == nil, "no backup without a previous file")

    let hooks = try #require(try json(installer.file(for: .claude))["hooks"] as? [String: [[String: Any]]])
    #expect(hooks.count == 10)
    let post = try #require(hooks["PostToolUse"]?.first)
    #expect(post["matcher"] as? String == "*")
    let command = try #require((post["hooks"] as? [[String: Any]])?.first)
    #expect(command["command"] as? String == "\"\(hookPath)\" claude PostToolUse")
    #expect(command["async"] as? Bool == true)
}

@Test func installKeepsTheUsersSettingsAndUninstallRestoresThem() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = HookInstaller(home: home, hookPath: hookPath)
    let file = installer.file(for: .claude)
    try write(existingClaudeSettings, to: file)
    let original = try json(file)

    let backup = try #require(try installer.apply(try installer.installPlan(for: .claude)))
    #expect(try String(contentsOf: backup, encoding: .utf8) == existingClaudeSettings)
    let installed = try json(file)
    #expect(installed["model"] as? String == "opus")
    let stop = try #require((installed["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
    #expect(stop.count == 2, "the user's own Stop hook plus Meanwhile's")

    try installer.apply(try installer.uninstallPlan(for: .claude))
    #expect(try json(file) == original)
}

@Test func installingTwiceDoesNotDuplicate() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = HookInstaller(home: home, hookPath: hookPath)
    try installer.apply(try installer.installPlan(for: .codex))
    let once = try json(installer.file(for: .codex))

    let again = try installer.installPlan(for: .codex)
    #expect(!again.changes)
    #expect(again.added.isEmpty)
    try installer.apply(again)
    #expect(try json(installer.file(for: .codex)) == once)
}

@Test func uninstallRemovesAHooksObjectOnlyMeanwhileUsed() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = HookInstaller(home: home, hookPath: hookPath)
    try write(#"{"model":"opus"}"#, to: installer.file(for: .claude))

    try installer.apply(try installer.installPlan(for: .claude))
    try installer.apply(try installer.uninstallPlan(for: .claude))
    #expect(try json(installer.file(for: .claude)) == ["model": "opus"])
}

@Test func uninstallWithNothingInstalledChangesNothing() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = HookInstaller(home: home, hookPath: hookPath)
    try write(existingClaudeSettings, to: installer.file(for: .claude))
    let plan = try installer.uninstallPlan(for: .claude)
    #expect(!plan.changes && plan.removed.isEmpty)
    // No config file at all: also nothing to do, and nothing gets created.
    let missing = try installer.uninstallPlan(for: .codex)
    #expect(!missing.changes)
    #expect(try installer.apply(missing) == nil)
    #expect(!FileManager.default.fileExists(atPath: installer.file(for: .codex).path))
}

@Test func oldMeanwhileEntriesAreReplaced() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    // A hook path from an earlier install, and an event Meanwhile no longer uses.
    try write("""
    {"hooks":{"Interrupt":[{"hooks":[{"type":"command","command":"\\"/old/meanwhile-hook\\" codex Interrupt"}]}]}}
    """, to: HookInstaller(home: home, hookPath: hookPath).file(for: .codex))
    let installer = HookInstaller(home: home, hookPath: hookPath)
    let plan = try installer.installPlan(for: .codex)
    #expect(plan.removed == ["Interrupt"])
    #expect(!plan.after.contains("/old/meanwhile-hook"))
}

@Test func malformedConfigIsLeftAlone() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = HookInstaller(home: home, hookPath: hookPath)
    try write("[1, 2]", to: installer.file(for: .claude))
    #expect(throws: InstallError.self) { try installer.installPlan(for: .claude) }
    try write("{ not json", to: installer.file(for: .codex))
    #expect(throws: (any Error).self) { try installer.installPlan(for: .codex) }
    #expect(try String(contentsOf: installer.file(for: .codex), encoding: .utf8) == "{ not json")
}

@Test func detectsInstalledAgents() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    #expect(HookInstaller(home: home, hookPath: hookPath).detectedAgents() == [.codex])
}

@Test func launchAgentPlistRunsMeanwhile() throws {
    let agent = LaunchAgent(home: URL(fileURLWithPath: "/Users/dev"), executable: "/Users/dev/.local/bin/meanwhile")
    let plist = try #require(try PropertyListSerialization.propertyList(from: agent.plist(), format: nil) as? [String: Any])
    #expect(plist["Label"] as? String == "dev.meanwhile.agent")
    #expect(plist["ProgramArguments"] as? [String] == ["/Users/dev/.local/bin/meanwhile", "run"])
    #expect((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
    #expect(agent.plistURL.path == "/Users/dev/Library/LaunchAgents/dev.meanwhile.agent.plist")
}
