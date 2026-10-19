import ArgumentParser
import Foundation
import MeanwhileCore
import MeanwhileIPC

extension MeanwhileCommand {
    /// `meanwhile setup`: hooks for each agent, the provider, start at login, a test question.
    /// The terminal version of the onboarding flow (docs/mvp-plan.md, "First run").
    struct Setup: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install the agent hooks and start Meanwhile in the background.")

        @Flag(name: .shortAndLong, help: "Accept every change without asking.")
        var yes = false

        @Flag(help: "Show what would change, and change nothing.")
        var dryRun = false

        @Option(help: "Agents to set up, comma-separated (claude, codex). Default: the ones installed.")
        var agents: String?

        @Flag(help: "Don't install the launch agent or start Meanwhile.")
        var noStart = false

        func run() throws {
            print("""
            Meanwhile asks short questions in the notch while your coding agent works:
            about your codebase, what the agent found, and decks you choose.

            """)
            let paths = try Binaries.locate()
            let installer = HookInstaller(hookPath: Binaries.installedHook.path)
            let chosen = try Setup.agents(agents, detected: installer.detectedAgents())
            guard !chosen.isEmpty else {
                print("No supported agent found (looked for ~/.claude and ~/.codex). Install Claude Code or Codex first.")
                throw ExitCode.failure
            }

            // 1. Show the plan.
            let plans = try chosen.map { try installer.installPlan(for: $0) }
            for plan in plans { Setup.describe(plan) }
            Setup.warnAboutProjectHooks()
            let provider = Provider.detect()
            print("Provider for questions: \(provider.map { "\($0) (found on your PATH)" } ?? "none found yet; codebase questions come later")")
            print("Install meanwhile and meanwhile-hook into \(Setup.tilde(Binaries.directory.path))")
            if !noStart { print("Start at login: \(Setup.tilde(LaunchAgent(executable: Binaries.installedApp.path).plistURL.path))") }
            print()

            if dryRun {
                print("Dry run: nothing was changed.")
                return
            }
            guard yes || Setup.confirm("Apply these changes?") else {
                print("Nothing changed.")
                return
            }

            // 2. Install.
            try Binaries.installHook(from: paths.hook)
            try Binaries.installApp(from: paths.meanwhile)
            for plan in plans where plan.changes {
                let backup = try installer.apply(plan)
                print("✓ \(plan.agent.displayName): updated \(Setup.tilde(plan.file.path))"
                      + (backup.map { " (backup: \($0.lastPathComponent))" } ?? ""))
            }
            if let provider { UserDefaults.standard.set(provider, forKey: Provider.key) }
            if chosen.contains(.codex) {
                print("""

                ! Codex skips new hooks until you trust them. In Codex, run /hooks and trust the
                  Meanwhile entries. Questions appear for Codex turns after that.
                """)
            }

            // 3. Start in the background, then show a question.
            guard !noStart else {
                print("\nDone. Start it yourself with: meanwhile run")
                return
            }
            try LaunchAgent(executable: Binaries.installedApp.path).install()
            print("✓ Meanwhile starts now and at every login.")
            guard Setup.waitForSocket() else {
                print("Meanwhile didn't start within 10 s. See \(Setup.tilde(LaunchAgent(executable: "").logURL.path)).")
                throw ExitCode.failure
            }
            if yes {
                print("\nDone. Send a prompt to your agent to see your first question.")
            } else {
                Setup.testQuestion()
            }
        }

        static func agents(_ requested: String?, detected: [HookInstaller.Agent]) throws -> [HookInstaller.Agent] {
            guard let requested else { return detected }
            return try requested.split(separator: ",").map {
                guard let agent = HookInstaller.Agent(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) else {
                    throw ValidationError("Unknown agent '\($0)'. Use claude or codex.")
                }
                return agent
            }
        }

        static func describe(_ plan: HookInstaller.Plan) {
            let file = tilde(plan.file.path)
            if !plan.changes {
                print("\(plan.agent.displayName): already set up in \(file)")
                return
            }
            print("\(plan.agent.displayName): \(file)\(plan.before == nil ? " (new file)" : "")")
            if !plan.added.isEmpty { print("  + hooks on \(plan.added.joined(separator: ", "))") }
            if plan.added.isEmpty { print("  ~ refresh Meanwhile's hooks") }
            if !plan.removed.isEmpty { print("  - old Meanwhile hooks on \(plan.removed.joined(separator: ", "))") }
            if plan.before != nil { print("  Your other settings and hooks are kept; the old file is backed up first.") }
        }

        /// The dev hook configs in a checkout of this repo would send every event twice.
        static func warnAboutProjectHooks() {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let candidates = [".claude/settings.json", ".claude/settings.local.json", ".codex/hooks.json"]
                .map { cwd.appendingPathComponent($0) }
                .filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains(HookInstaller.marker) == true }
            for file in candidates {
                print("! \(tilde(file.path)) also runs meanwhile-hook. Remove those entries, or events from this folder arrive twice.")
            }
        }

        /// Sends one fake prompt so a question opens, then ends the fake turn.
        static func testQuestion() {
            let session = "meanwhile-setup-\(UUID().uuidString.prefix(8))"
            let cwd = FileManager.default.currentDirectoryPath
            send("UserPromptSubmit", ["prompt": "meanwhile setup test"], session: session, cwd: cwd)
            print("\nA question should be in your notch now. Answer it, or press Enter to finish.")
            _ = readLine()
            send("Stop", ["last_assistant_message": "Setup test finished."], session: session, cwd: cwd)
            send("SessionEnd", ["reason": "setup"], session: session, cwd: cwd)
            print("Done. Send a prompt to your agent to see your first real question.")
        }

        private static func send(_ event: String, _ fields: [String: String], session: String, cwd: String) {
            var payload: [String: Any] = fields
            payload["hook_event_name"] = event
            payload["session_id"] = session
            payload["cwd"] = cwd
            guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return }
            let line = Wire.envelope(agent: "claude", event: event, payload: json,
                                     environment: ProcessInfo.processInfo.environment, parentPID: getppid())
            _ = UnixSocket.send(line, to: MeanwhilePaths.socket.path)
        }

        static func waitForSocket(timeout: TimeInterval = 10) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if UnixSocket.send(Data(), to: MeanwhilePaths.socket.path) { return true }
                usleep(200_000)
            }
            return false
        }

        static func confirm(_ question: String) -> Bool {
            print("\(question) [y/N] ", terminator: "")
            return ["y", "yes"].contains(readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? "")
        }

        static func tilde(_ path: String) -> String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        }
    }

    /// `meanwhile uninstall`: removes the hooks, the launch agent and the installed hook.
    /// Progress and stored events stay unless deleted by hand.
    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove the agent hooks and stop Meanwhile.")

        @Flag(name: .shortAndLong, help: "Remove without asking.")
        var yes = false

        func run() throws {
            let installer = HookInstaller(hookPath: Binaries.installedHook.path)
            let plans = try HookInstaller.Agent.allCases.map { try installer.uninstallPlan(for: $0) }.filter(\.changes)
            for plan in plans {
                print("\(plan.agent.displayName): remove Meanwhile's hooks on \(plan.removed.joined(separator: ", ")) from \(Setup.tilde(plan.file.path))")
            }
            print("Stop Meanwhile and remove it from login items.")
            guard yes || Setup.confirm("Remove?") else {
                print("Nothing changed.")
                return
            }
            for plan in plans {
                let backup = try installer.apply(plan)
                print("✓ \(plan.agent.displayName): hooks removed" + (backup.map { " (backup: \($0.lastPathComponent))" } ?? ""))
            }
            try LaunchAgent(executable: "").uninstall()
            try? FileManager.default.removeItem(at: Binaries.directory)
            print("""
            ✓ Meanwhile is stopped and won't start at login.
            Your progress and recent events are still in \(Setup.tilde(MeanwhilePaths.supportDirectory.path)).
            Delete that folder to remove them too.
            """)
        }
    }
}

/// Where `meanwhile` and `meanwhile-hook` are, and where they are installed.
///
/// Both are copied into ~/Library/Application Support/Meanwhile/bin. The login item can't
/// run them from a checkout under ~/Desktop, ~/Documents or ~/Downloads: macOS privacy
/// protection hides those folders from launchd-started processes (seen 2026-10-19).
enum Binaries {
    static var directory: URL { MeanwhilePaths.supportDirectory.appendingPathComponent("bin", isDirectory: true) }
    static var installedHook: URL { directory.appendingPathComponent("meanwhile-hook") }
    static var installedApp: URL { directory.appendingPathComponent("meanwhile") }

    /// This executable and the `meanwhile-hook` built or shipped next to it.
    static func locate() throws -> (meanwhile: URL, hook: URL) {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        let hook = executable.deletingLastPathComponent().appendingPathComponent("meanwhile-hook")
        guard FileManager.default.isExecutableFile(atPath: hook.path) else {
            throw InstallError.missingHookBinary(hook.path)
        }
        return (executable, hook)
    }

    /// Copies the hook where agent configs point, replacing any older copy.
    static func installHook(from source: URL) throws {
        try copy(source, to: installedHook)
    }

    /// Copies `meanwhile` and the SwiftPM resource bundles beside it (the decks) into place.
    static func installApp(from executable: URL) throws {
        try copy(executable, to: installedApp)
        let built = executable.deletingLastPathComponent()
        let bundles = try FileManager.default.contentsOfDirectory(at: built, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "bundle" && !$0.lastPathComponent.contains("Tests") }
        for bundle in bundles {
            try copy(bundle, to: directory.appendingPathComponent(bundle.lastPathComponent))
        }
    }

    /// Replaces `destination` with a copy of `source` without leaving a half-written file.
    private static func copy(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = destination.appendingPathExtension("new")
        try? fileManager.removeItem(at: staged)
        try fileManager.copyItem(at: source, to: staged)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }
}

/// Which CLI generates questions (task 2.3 adds the provider layer; this records the choice).
enum Provider {
    static let key = "provider"

    /// `codex` if installed (the default since 2026-10-19), else `claude`.
    static func detect() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init)
        return ["codex", "claude"].first { name in
            directories.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
        }
    }
}
