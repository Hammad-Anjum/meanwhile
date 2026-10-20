import Foundation
import GRDB
import MeanwhileIPC

/// `meanwhile doctor`: a read-only self-check for support. Each check looks at one piece of
/// the install and returns a fact, plus the exact command that fixes a problem.
///
/// Nothing here writes: configs are parsed, databases are opened read-only (so no migration
/// runs), and the socket probe sends no event. Provider logins are checked only by running
/// the provider's own CLI; its credential files are never read.
public enum Doctor {
    public struct Check: Sendable, Equatable, Codable {
        public enum Status: String, Sendable, Codable {
            case ok, warning, failure

            public var symbol: String {
                switch self {
                case .ok: "✓"
                case .warning: "!"
                case .failure: "✗"
                }
            }
        }

        /// Short stable id for `--json`, e.g. "hooks.claude".
        public var id: String
        public var status: Status
        public var fact: String
        /// The command (or step) that fixes it, for warnings and failures.
        public var fix: String?

        public init(_ id: String, _ status: Status, _ fact: String, fix: String? = nil) {
            self.id = id
            self.status = status
            self.fact = fact
            self.fix = fix
        }
    }

    // MARK: Report

    /// One line per check, and an indented "Fix:" line under each problem.
    public static func format(_ checks: [Check]) -> String {
        checks.map { check in
            var line = "\(check.status.symbol) \(check.fact)"
            if check.status != .ok, let fix = check.fix { line += "\n    Fix: \(fix)" }
            return line
        }.joined(separator: "\n")
    }

    /// 1 if any check failed; warnings alone still exit 0.
    public static func exitCode(_ checks: [Check]) -> Int32 {
        checks.contains { $0.status == .failure } ? 1 : 0
    }

    /// The report as JSON, for pasting into a bug report.
    public static func json(_ checks: [Check], version: String, date: Date = Date()) throws -> Data {
        struct Report: Encodable {
            let version: String
            let date: String
            let checks: [Check]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Report(version: version, date: ISO8601DateFormatter().string(from: date), checks: checks))
    }

    // MARK: System

    public static func system(version: OperatingSystemVersion, architecture: String) -> Check {
        let text = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        guard version.majorVersion >= 14 else {
            return Check("macos", .failure, "macOS \(text) on \(architecture); Meanwhile needs macOS 14 or later",
                         fix: "Update macOS in System Settings > General > Software Update")
        }
        return Check("macos", .ok, "macOS \(text) on \(architecture)")
    }

    /// The machine's architecture, e.g. "arm64".
    public static var architecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    // MARK: Installed binaries

    /// What `meanwhile setup` copies into `directory`: both programs and the resource bundles.
    /// `installedVersion` is what the installed `meanwhile --version` printed, nil if it didn't run.
    public static func binaries(directory: URL, runningVersion: String, installedVersion: String?,
                                sameBuild: Bool?) -> [Check] {
        let fileManager = FileManager.default
        let app = directory.appendingPathComponent("meanwhile").path
        let hook = directory.appendingPathComponent("meanwhile-hook").path
        let bundles = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".bundle") }.sorted()
        let missing = [("meanwhile", app), ("meanwhile-hook", hook)]
            .filter { !fileManager.isExecutableFile(atPath: $0.1) }.map(\.0)
            + (bundles.contains("MeanwhileKit_MeanwhileCore.bundle") ? [] : ["MeanwhileKit_MeanwhileCore.bundle (decks)"])
        let place = tilde(directory.path)
        var checks: [Check] = []
        if missing.isEmpty {
            checks.append(Check("install.files", .ok, "Installed in \(place): meanwhile, meanwhile-hook, \(bundles.joined(separator: ", "))"))
        } else {
            checks.append(Check("install.files", .failure, "Missing from \(place): \(missing.joined(separator: ", "))",
                                fix: "meanwhile setup"))
        }
        guard fileManager.isExecutableFile(atPath: app) else { return checks }
        switch installedVersion {
        case nil:
            checks.append(Check("install.version", .failure, "The installed meanwhile didn't report a version",
                                fix: "meanwhile setup"))
        case runningVersion? where sameBuild == false:
            checks.append(Check("install.version", .warning,
                                "Installed meanwhile is \(runningVersion), same version but a different build from this one",
                                fix: "Run setup from the build you want installed: meanwhile setup"))
        case runningVersion?:
            checks.append(Check("install.version", .ok, "Installed meanwhile is \(runningVersion), same as this one"))
        case let other?:
            checks.append(Check("install.version", .warning, "Installed meanwhile is \(other); this one is \(runningVersion)",
                                fix: "meanwhile setup"))
        }
        return checks
    }

    /// Which `meanwhile` a terminal runs, given its PATH.
    public static func onPath(_ path: String, installed: URL) -> Check {
        let installedPath = installed.resolvingSymlinksInPath().path
        // The same link install.sh makes, plus the PATH line in case ~/.local/bin isn't on it.
        let fix = "mkdir -p ~/.local/bin && ln -sf \"$HOME/Library/Application Support/Meanwhile/bin/meanwhile\" ~/.local/bin/meanwhile"
            + (path.split(separator: ":").contains { $0.hasSuffix("/.local/bin") } ? ""
               : " && echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zprofile")
        guard let found = which("meanwhile", path: path) else {
            return Check("install.path", .warning, "meanwhile is not on your PATH", fix: fix)
        }
        let resolved = URL(fileURLWithPath: found).resolvingSymlinksInPath().path
        if resolved == installedPath {
            return Check("install.path", .ok, "meanwhile on PATH: \(tilde(found))")
        }
        return Check("install.path", .warning, "meanwhile on PATH is \(tilde(found)), not the installed copy",
                     fix: "Remove that copy, or put the installed one first: \(fix)")
    }

    /// The first executable called `name` in a PATH string.
    public static func which(_ name: String, path: String) -> String? {
        path.split(separator: ":").map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Login item

    /// Whether `launchctl print` says the job is loaded and running.
    public struct LaunchStatus: Sendable, Equatable {
        public var loaded: Bool
        public var running: Bool
        public var pid: Int?
        public var lastExit: String?

        public init(loaded: Bool, running: Bool, pid: Int? = nil, lastExit: String? = nil) {
            self.loaded = loaded
            self.running = running
            self.pid = pid
            self.lastExit = lastExit
        }

        /// Reads `launchctl print gui/<uid>/<label>` output; `status` is its exit code.
        public init(launchctlStatus status: Int32, output: String) {
            func value(_ key: String) -> String? {
                output.components(separatedBy: .newlines).lazy
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { $0.hasPrefix(key + " = ") }
                    .map { String($0.dropFirst(key.count + 3)) }
            }
            loaded = status == 0
            running = loaded && value("state") == "running"
            pid = value("pid").flatMap { Int($0) }
            lastExit = value("last exit code")
        }
    }

    public static func loginItem(plist: URL, launch: LaunchStatus, uid: uid_t = getuid()) -> [Check] {
        let target = "gui/\(uid)/\(LaunchAgent.label)"
        guard FileManager.default.fileExists(atPath: plist.path) else {
            return [Check("login.plist", .failure, "No login item at \(tilde(plist.path))", fix: "meanwhile setup")]
        }
        var checks: [Check] = []
        // The plist should run an executable that exists.
        let object = (try? Data(contentsOf: plist))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let program = (object?["ProgramArguments"] as? [String])?.first
        if let program, FileManager.default.isExecutableFile(atPath: program) {
            checks.append(Check("login.plist", .ok, "Login item \(tilde(plist.path)) runs \(tilde(program))"))
        } else {
            checks.append(Check("login.plist", .failure,
                                "Login item \(tilde(plist.path)) runs \(program.map(tilde) ?? "nothing"), which doesn't exist",
                                fix: "meanwhile setup"))
        }
        if !launch.loaded {
            checks.append(Check("login.loaded", .failure, "Login item is not loaded in launchd",
                                fix: "launchctl bootstrap gui/\(uid) \(shellQuoted(plist.path))"))
        } else if launch.running {
            checks.append(Check("login.running", .ok, "Meanwhile is running" + (launch.pid.map { " (pid \($0))" } ?? "")))
        } else {
            let exit = launch.lastExit.map { " (last exit: \($0))" } ?? ""
            checks.append(Check("login.running", .failure, "Login item is loaded but Meanwhile isn't running\(exit)",
                                fix: "launchctl kickstart \(target)"))
        }
        return checks
    }

    // MARK: Socket and spool

    /// `answers` is whether a connection to the socket succeeded.
    public static func socket(path: String, answers: Bool, uid: uid_t = getuid()) -> Check {
        if answers { return Check("socket", .ok, "The app answers on its socket") }
        let exists = FileManager.default.fileExists(atPath: path)
        return Check("socket", .failure,
                     exists ? "Nothing answers on \(tilde(path)); hook events go to the spool"
                            : "No socket at \(tilde(path)); the app isn't listening and hook events go to the spool",
                     fix: "launchctl kickstart -k gui/\(uid)/\(LaunchAgent.label)")
    }

    /// Events waiting in the spool, counted as lines. The app takes them only when it starts.
    public static func spoolBacklog(directory: URL) -> Int {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0 == "events.ndjson" || ($0.hasPrefix("draining-") && $0.hasSuffix(".ndjson")) }
        return files.reduce(0) { total, name in
            let data = (try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data()
            return total + data.split(separator: 0x0A).count
        }
    }

    public static func spool(backlog: Int, appAnswers: Bool, uid: uid_t = getuid()) -> Check {
        guard backlog > 0 else { return Check("spool", .ok, "No events waiting in the spool") }
        return Check("spool", .warning,
                     "\(backlog) event\(backlog == 1 ? "" : "s") waiting in the spool (sent while the app was down)",
                     fix: (appAnswers ? "Restart the app to take them: " : "Start the app: ")
                        + "launchctl kickstart -k gui/\(uid)/\(LaunchAgent.label)")
    }

    // MARK: Hooks

    /// Meanwhile's hook entries in one agent's config, read without changing anything.
    public struct HookScan: Sendable, Equatable {
        /// The agent's directory (~/.claude, ~/.codex) exists.
        public var agentInstalled: Bool
        public var file: URL
        /// The file is there but isn't a JSON object.
        public var unreadable: Bool
        /// Events with a Meanwhile entry.
        public var events: [String]
        /// Events Meanwhile listens to that have no entry.
        public var missing: [String]
        /// The hook executables the entries run, deduplicated.
        public var commands: [String]
    }

    public static func scanHooks(_ agent: HookInstaller.Agent, home: URL) -> HookScan {
        let file = home.appendingPathComponent(agent.configPath)
        let installed = FileManager.default.fileExists(atPath: home.appendingPathComponent(agent.homeDirectory).path)
        var scan = HookScan(agentInstalled: installed, file: file, unreadable: false, events: [], missing: [], commands: [])
        if let data = try? Data(contentsOf: file),
           !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                scan.unreadable = true
                scan.missing = agent.events.map(\.name)
                return scan
            }
            let hooks = object["hooks"] as? [String: Any] ?? [:]
            for (event, value) in hooks {
                let commands = (value as? [[String: Any]] ?? [])
                    .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                    .compactMap { $0["command"] as? String }
                    .filter { $0.contains(HookInstaller.marker) }
                guard !commands.isEmpty else { continue }
                scan.events.append(event)
                for command in commands.map(executable) where !scan.commands.contains(command) {
                    scan.commands.append(command)
                }
            }
        }
        scan.events.sort()
        scan.missing = agent.events.map(\.name).filter { !scan.events.contains($0) }
        return scan
    }

    /// The program a hook command runs: the quoted first word, or the first word.
    static func executable(of command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\""), let end = trimmed.dropFirst().firstIndex(of: "\"") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
        }
        return String(trimmed.split(separator: " ").first ?? "")
    }

    public static func hooks(_ agent: HookInstaller.Agent, scan: HookScan) -> Check {
        let id = "hooks.\(agent.rawValue)"
        let name = agent.displayName
        let file = tilde(scan.file.path)
        let fix = "meanwhile setup --agents \(agent.rawValue)"
        if scan.unreadable {
            return Check(id, .failure, "\(name): \(file) is not valid JSON, so no hooks run",
                         fix: "Fix the JSON in \(file), then run: \(fix)")
        }
        if scan.events.isEmpty {
            guard scan.agentInstalled else { return Check(id, .ok, "\(name) not installed; no hooks needed") }
            return Check(id, .failure, "\(name): no Meanwhile hooks in \(file)", fix: fix)
        }
        let broken = scan.commands.filter { !FileManager.default.isExecutableFile(atPath: $0) }
        if !broken.isEmpty {
            return Check(id, .failure, "\(name): hooks run \(broken.map(tilde).joined(separator: ", ")), which doesn't exist",
                         fix: fix)
        }
        if !scan.missing.isEmpty {
            return Check(id, .warning, "\(name): hooks missing for \(scan.missing.joined(separator: ", ")) in \(file)",
                         fix: fix)
        }
        return Check(id, .ok, "\(name): \(scan.events.count) hooks in \(file) run \(scan.commands.map(tilde).joined(separator: ", "))")
    }

    /// Codex ignores new hooks until the user trusts them with /hooks; Codex records that in
    /// ~/.codex/config.toml (read by `CodexHookTrust`). Nil when there are no Codex hooks.
    public static func codexTrust(_ status: CodexHookTrust.Status) -> Check? {
        let fix = "In Codex, run /hooks and trust the Meanwhile entries"
        switch status {
        case .noHooks:
            return nil
        case .trusted:
            return Check("hooks.codex.trust", .ok, "Codex trusts Meanwhile's hooks")
        case .untrusted(let events):
            return Check("hooks.codex.trust", .failure,
                         "Codex hasn't trusted Meanwhile's hooks for \(events.joined(separator: ", ")); Codex turns show no questions",
                         fix: fix)
        }
    }

    // MARK: Provider

    /// The provider name `meanwhile setup` recorded, as `Providers.configured()` reads it.
    public static func configuredProvider(defaults: UserDefaults = .standard) -> String {
        Providers.configured(defaults: defaults).name
    }

    /// Whether the provider CLI is on PATH. `path` is where it was found.
    public static func providerCLI(_ name: String, path: String?) -> Check {
        guard let path else {
            let install = name == "codex" ? "npm install -g @openai/codex" : "npm install -g @anthropic-ai/claude-code"
            return Check("provider.cli", .failure, "Provider \(name): \(name) is not on your PATH", fix: install)
        }
        return Check("provider.cli", .ok, "Provider \(name): \(tilde(path))")
    }

    /// The provider CLI's own login-status command, run without reading its credentials.
    public static func loginStatusCommand(for provider: String) -> [String] {
        provider == "claude" ? ["auth", "status", "--text"] : ["login", "status"]
    }

    /// Reads the output of `loginStatusCommand`. Lines with an email address are left out.
    public static func providerLogin(_ name: String, status: Int32, output: String, timedOut: Bool = false) -> Check {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("@") }
        let summary = lines.first.map { ": \($0.prefix(120))" } ?? ""
        let login = name == "claude" ? "claude auth login" : "codex login"
        if timedOut { return Check("provider.login", .warning, "\(name) login status didn't answer in time", fix: login) }
        guard status == 0 else {
            return Check("provider.login", .failure, "\(name) is not logged in\(summary)", fix: login)
        }
        return Check("provider.login", .ok, "\(name) is logged in\(summary)")
    }

    /// Runs the provider's own login-status command, with the environment model calls get.
    public static func checkProviderLogin(_ name: String) -> Check {
        do {
            let result = try Shell.run(name, loginStatusCommand(for: name), environment: CLICall.environment,
                                       timeout: 15, maximumOutputBytes: 64 * 1024)
            return providerLogin(name, status: result.status, output: result.text + "\n" + result.stderr,
                                 timedOut: result.timedOut)
        } catch {
            return Check("provider.login", .warning, "Couldn't run \(name) to check its login: \(error)",
                         fix: name == "claude" ? "claude auth status" : "codex login status")
        }
    }

    /// The prompt and schema `meanwhile model-check` uses, for `doctor --model`.
    public static let samplePrompt =
        "Write one multiple-choice question (4 options, one correct) about what a SQLite WAL file is for."
    public static var sampleSchema: [String: Any] {
        [
            "type": "object", "additionalProperties": false,
            "required": ["question", "options", "correct"],
            "properties": [
                "question": ["type": "string"],
                "options": ["type": "array", "items": ["type": "string"], "minItems": 4, "maxItems": 4],
                "correct": ["type": "integer", "minimum": 0, "maximum": 3],
            ],
        ]
    }

    /// One real call to the model, timed. Makes a request on the user's plan.
    public static func modelCall(_ model: QuestionModel) -> Check {
        let start = Date()
        do {
            _ = try model.generate(prompt: samplePrompt, schema: sampleSchema)
            return Check("provider.call", .ok, String(format: "%@ answered a test question in %.1f s",
                                                      model.name, Date().timeIntervalSince(start)))
        } catch {
            let login = model.name == "claude" ? "claude auth login" : "codex login"
            return Check("provider.call", .failure, "\(model.name) test call failed: \(error)",
                         fix: "Check the login (\(login)), then: meanwhile model-check")
        }
    }

    // MARK: Databases

    /// What one store file looks like, opened read-only.
    public struct DatabaseInfo: Sendable, Equatable {
        public var name: String
        public var exists: Bool
        /// Bytes, including the WAL.
        public var size: Int64
        public var applied: [String]
        public var error: String?
    }

    /// Opens `url` read-only, so no migration runs and nothing is written.
    public static func inspectDatabase(_ url: URL) -> DatabaseInfo {
        let name = url.lastPathComponent
        let size = ["", "-wal"].reduce(Int64(0)) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DatabaseInfo(name: name, exists: false, size: 0, applied: [])
        }
        do {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            let applied = try queue.read { db in
                try db.tableExists("grdb_migrations")
                    ? String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") : []
            }
            return DatabaseInfo(name: name, exists: true, size: size, applied: applied)
        } catch {
            return DatabaseInfo(name: name, exists: true, size: size, applied: [], error: "\(error)")
        }
    }

    /// Migrations this build registers for each store file, read from fresh in-memory stores.
    /// The stores keep their migrators private, so this asks GRDB what a new store applied.
    public static func registeredMigrations() -> [String: [String]] {
        func applied(_ store: AnyObject) -> [String] {
            guard let writer = Mirror(reflecting: store).children.first(where: { $0.label == "writer" })?.value
                    as? any DatabaseWriter else { return [] }
            return (try? writer.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }) ?? []
        }
        var result: [String: [String]] = [:]
        if let store = try? EventStore(path: nil) { result[MeanwhilePaths.eventStore.lastPathComponent] = applied(store) }
        if let store = try? ReviewStore(path: nil) { result[MeanwhilePaths.reviewStore.lastPathComponent] = applied(store) }
        if let store = try? LibraryStore(path: nil) { result[MeanwhilePaths.libraryStore.lastPathComponent] = applied(store) }
        return result
    }

    /// `registered` is nil when this build's list couldn't be read.
    public static func database(_ info: DatabaseInfo, registered: [String]?, uid: uid_t = getuid()) -> Check {
        let id = "db.\(info.name)"
        guard info.exists else {
            return Check(id, .warning, "\(info.name) doesn't exist yet (created when the app first runs)",
                         fix: "launchctl kickstart gui/\(uid)/\(LaunchAgent.label)")
        }
        let size = ByteCountFormatter.string(fromByteCount: info.size, countStyle: .file)
        if let error = info.error {
            return Check(id, .failure, "\(info.name) (\(size)) doesn't open: \(error)",
                         fix: "Send this report; keep the file, it holds your progress")
        }
        guard let registered, !registered.isEmpty else {
            return Check(id, .ok, "\(info.name): \(size), \(info.applied.count) migrations applied")
        }
        let unknown = info.applied.filter { !registered.contains($0) }
        let pending = registered.filter { !info.applied.contains($0) }
        if !unknown.isEmpty {
            return Check(id, .failure, "\(info.name): \(size), written by a newer Meanwhile (\(unknown.joined(separator: ", ")))",
                         fix: "Install the newer Meanwhile again: meanwhile setup")
        }
        if !pending.isEmpty {
            return Check(id, .warning,
                         "\(info.name): \(size), \(pending.count) migration\(pending.count == 1 ? "" : "s") pending (\(pending.joined(separator: ", ")))",
                         fix: "Restart the app to apply them: launchctl kickstart -k gui/\(uid)/\(LaunchAgent.label)")
        }
        return Check(id, .ok, "\(info.name): \(size), up to date (\(info.applied.count) migration\(info.applied.count == 1 ? "" : "s"))")
    }

    // MARK: Config

    /// Parses the settings file the way `UserSettings.load` does, but reports what it skips.
    public static func config(_ url: URL) -> Check {
        let place = tilde(url.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Check("config", .ok, "No \(place); defaults: \(pacing(UserSettings()))")
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Check("config", .failure, "\(place) can't be read as UTF-8 text",
                         fix: "Check the file, or delete it to use the defaults: rm \(shellQuoted(url.path))")
        }
        var settings = UserSettings()
        var problems: [String] = []
        var fixes: [String] = []
        for (key, value) in UserSettings.parse(text) {
            do {
                try settings.set(key, to: value)
            } catch let error as SettingsError {
                problems.append(error.description)
                if case .invalid = error { fixes.append("meanwhile config \(key) <value>") }
            } catch {
                problems.append("\(key): \(error)")
            }
        }
        if problems.isEmpty { return Check("config", .ok, "\(place): \(pacing(settings))") }
        return Check("config", .warning, "\(place): \(problems.joined(separator: " ")) Using: \(pacing(settings))",
                     fix: fixes.isEmpty ? "Edit \(place), or see the keys with: meanwhile config" : fixes.joined(separator: "; "))
    }

    static func pacing(_ settings: UserSettings) -> String {
        UserSettings.keys.map { "\($0.name) = \(settings.value(of: $0.name) ?? "")" }.joined(separator: ", ")
    }

    // MARK: Repos and budget

    public struct LibrarySummary: Sendable, Equatable {
        public var projects: Int
        public var on: Int
        public var callsToday: Int
    }

    /// Counts projects (a repo and its worktrees count once) and today's model calls, read-only.
    public static func librarySummary(_ url: URL, now: Date = Date()) throws -> LibrarySummary {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return try queue.read { db in
            guard try db.tableExists("repo") else { return LibrarySummary(projects: 0, on: 0, callsToday: 0) }
            let hasProjects = try db.columns(in: "repo").contains { $0.name == "projectRoot" }
            let projects = hasProjects ? "WHERE (projectRoot IS NULL OR projectRoot = root)" : ""
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM repo \(projects)") ?? 0
            let on = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM repo \(projects.isEmpty ? "WHERE" : projects + " AND") state = 'on'") ?? 0
            let calls = try db.tableExists("generationCall")
                ? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM generationCall WHERE calledAt >= ?",
                               arguments: [Calendar.current.startOfDay(for: now)]) ?? 0
                : 0
            return LibrarySummary(projects: total, on: on, callsToday: calls)
        }
    }

    public static func repos(_ summary: LibrarySummary) -> Check {
        guard summary.projects > 0 else {
            return Check("repos", .ok, "No repos yet; send your agent a prompt in a repo")
        }
        let fact = "\(summary.projects) repo\(summary.projects == 1 ? "" : "s"), \(summary.on) with codebase questions on"
        return Check("repos", .ok, fact)
    }

    /// `limit` is `GenerationBudget`'s daily default.
    public static func budget(callsToday: Int, limit: Int = 20) -> Check {
        if callsToday >= limit {
            return Check("budget", .warning, "Model calls today: \(callsToday) of \(limit); no new codebase questions until tomorrow",
                         fix: "Nothing to do; the budget resets at midnight")
        }
        return Check("budget", .ok, "Model calls today: \(callsToday) of \(limit)")
    }

    // MARK: Log

    public static func log(_ url: URL) -> Check {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return Check("log", .ok, "No log yet at \(tilde(url.path))")
        }
        let text = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        if size > 50 * 1024 * 1024 {
            return Check("log", .warning, "Log \(tilde(url.path)) is \(text)",
                         fix: "Empty it: : > \(shellQuoted(url.path))")
        }
        return Check("log", .ok, "Log \(tilde(url.path)) (\(text))")
    }

    // MARK: Helpers

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A path quoted for pasting into a shell, with ~ kept outside the quotes.
    static func shellQuoted(_ path: String) -> String {
        let short = tilde(path)
        let body = short.hasPrefix("~/") ? String(short.dropFirst(2)) : short
        let quoted = body.contains(" ") ? "\"\(body)\"" : body
        return short.hasPrefix("~/") ? "~/" + quoted : quoted
    }
}
