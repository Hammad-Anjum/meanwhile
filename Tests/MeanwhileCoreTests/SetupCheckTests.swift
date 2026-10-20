import Foundation
import Testing
@testable import MeanwhileCore

/// The checks `meanwhile setup` and `uninstall --purge` rely on: the provider test call
/// (against fake CLIs), Codex hook trust, and the purge list, in throwaway folders.

private func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes an executable script and returns its path.
private func fakeCLI(_ name: String, _ body: String) throws -> String {
    let url = try temporaryDirectory("cli").appendingPathComponent(name)
    try Data("#!/bin/zsh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

// MARK: - Provider check

@Test func workingProviderAnswers() throws {
    let claude = try fakeCLI("claude", #"echo '{"is_error":false,"structured_output":{"ok":true}}'"#)
    let result = ProviderCheck.run(provider: "claude", executable: claude)
    #expect(result.succeeded)
    #expect(ProviderCheck.message(for: result, provider: "claude").hasPrefix("✓ claude answered in "))
}

@Test func expiredClaudeLoginSaysToLogIn() throws {
    let claude = try fakeCLI("claude", #"echo '{"is_error":true,"result":"Not logged in · Please run /login"}'"#)
    let result = ProviderCheck.run(provider: "claude", executable: claude)
    #expect(result == .notLoggedIn("Not logged in · Please run /login"))
    #expect(ProviderCheck.message(for: result, provider: "claude").contains("run `claude`, then type `/login`"))
}

@Test func codexLoginFailureSaysCodexLogin() throws {
    let codex = try fakeCLI("codex", "echo 'some progress'; echo 'Error: 401 Unauthorized: token expired' >&2; exit 1")
    let result = ProviderCheck.run(provider: "codex", executable: codex)
    #expect(result == .notLoggedIn("Error: 401 Unauthorized: token expired"))
    #expect(ProviderCheck.message(for: result, provider: "codex").contains("Fix: run `codex login`."))
}

@Test func otherFailuresKeepTheCLIsReason() throws {
    let codex = try fakeCLI("codex", "echo 'usage limit reached' >&2; exit 1")
    let result = ProviderCheck.run(provider: "codex", executable: codex)
    #expect(result == .failed("usage limit reached"))
    #expect(ProviderCheck.message(for: result, provider: "codex").hasPrefix("! codex failed: usage limit reached."))
}

@Test func missingAndSlowProvidersAreExplained() throws {
    let missing = ProviderCheck.run(provider: "codex", executable: "meanwhile-no-such-cli")
    #expect(missing == .notInstalled)
    #expect(ProviderCheck.message(for: missing, provider: "codex").contains("npm install -g @openai/codex"))
    #expect(ProviderCheck.message(for: .notInstalled, provider: "claude").contains("@anthropic-ai/claude-code"))

    let slow = ProviderCheck.run(provider: "codex", timeout: 0.5, executable: try fakeCLI("codex", "sleep 5"))
    #expect(slow == .timedOut(0.5))
    #expect(ProviderCheck.message(for: slow, provider: "codex").hasPrefix("! codex didn't answer within 0 s"))
}

// MARK: - Codex hook trust

@Test func codexTrustFollowsConfigState() throws {
    let home = try temporaryDirectory("home")
    let trust = CodexHookTrust(home: home)
    #expect(trust.check() == .noHooks)

    // The user's own Stop hook comes first, so Meanwhile's Stop entry is group 1.
    try write("""
    {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}
    """, to: home.appendingPathComponent(".codex/hooks.json"))
    try HookInstaller(home: home, hookPath: "/x/meanwhile-hook").apply(
        HookInstaller(home: home, hookPath: "/x/meanwhile-hook").installPlan(for: .codex))
    let hooksFile = home.appendingPathComponent(".codex/hooks.json").path
    guard case .untrusted(let all) = trust.check() else { Issue.record("expected untrusted"); return }
    #expect(all.count == HookInstaller.Agent.codex.events.count)

    // Trust every event but PostToolUse; SessionEnd in the inline form, Stop turned off.
    var config = "model = \"gpt-5\"\n\n[hooks.state]\n"
    config += "\"\(hooksFile):session_end:0:0\" = { trusted_hash = \"sha256:aa\" }\n"
    for (event, group) in [("session_start", 0), ("user_prompt_submit", 0), ("permission_request", 0),
                           ("subagent_stop", 0), ("stop", 1)] {
        config += "\n[hooks.state.\"\(hooksFile):\(event):\(group):0\"]\ntrusted_hash = \"sha256:bb\"\n"
        if event == "stop" { config += "enabled = false\n" }
    }
    try write(config, to: home.appendingPathComponent(".codex/config.toml"))
    #expect(trust.check() == .untrusted(["PostToolUse", "Stop"]))

    config = config.replacingOccurrences(of: "enabled = false\n", with: "")
    config += "\n[hooks.state.\"\(hooksFile):post_tool_use:0:0\"]\ntrusted_hash = \"sha256:cc\"\n"
    try write(config, to: home.appendingPathComponent(".codex/config.toml"))
    #expect(trust.check() == .trusted)
}

@Test func codexEventNamesAreSnakeCase() {
    #expect(CodexHookTrust.snakeCase("PostToolUse") == "post_tool_use")
    #expect(CodexHookTrust.snakeCase("Stop") == "stop")
}

// MARK: - Purge

@Test func purgeListsEveryDataFolder() {
    let home = URL(fileURLWithPath: "/Users/someone")
    #expect(Purge.targets(home: home, environment: [:]).map(\.path) == [
        "/Users/someone/Library/Application Support/Meanwhile",
        "/Users/someone/.config/meanwhile",
        "/Users/someone/Library/Logs/Meanwhile",
    ])
    #expect(Purge.targets(home: home, environment: ["XDG_CONFIG_HOME": "/tmp/xdg"])[1].path == "/tmp/xdg/meanwhile")
    // A relative XDG_CONFIG_HOME is ignored, as UserSettings does.
    #expect(Purge.targets(home: home, environment: ["XDG_CONFIG_HOME": "rel"])[1].path == "/Users/someone/.config/meanwhile")
}

@Test func purgeDeletesOnlyWhatExists() throws {
    let home = try temporaryDirectory("home")
    let targets = Purge.targets(home: home, environment: [:])
    try write("12345", to: targets[0].appendingPathComponent("spool/1.ndjson"))
    try write("abc", to: targets[0].appendingPathComponent("reviews.sqlite"))
    try write("x", to: targets[2].appendingPathComponent("meanwhile.log"))
    try write("keep", to: home.appendingPathComponent(".config/other/settings"))

    let existing = Purge.existing(targets)
    #expect(existing.map(\.url) == [targets[0], targets[2]])
    #expect(existing.map(\.bytes) == [8, 1])

    try Purge.remove(targets)
    #expect(targets.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/other/settings").path))
}
