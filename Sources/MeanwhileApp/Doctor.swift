import ArgumentParser
import Foundation
import MeanwhileCore
import MeanwhileIPC

extension MeanwhileCommand {
    /// `meanwhile doctor`: checks the install, one line per check, for support. Read-only:
    /// it changes no file, starts or stops nothing, and stores no event (see `Doctor`).
    struct Doctor: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check that Meanwhile is installed and working.",
            discussion: "Changes nothing. Exits with 1 if a check fails (✗); ! is a warning.")

        @Flag(help: "Print the report as JSON, for a bug report.")
        var json = false

        @Flag(help: "Also make one real model call with the configured provider (uses your plan).")
        var model = false

        func run() throws {
            let checks = Doctor.checks(model: model)
            if json {
                print(String(decoding: try MeanwhileCore.Doctor.json(checks, version: Meanwhile.version), as: UTF8.self))
            } else {
                print(MeanwhileCore.Doctor.format(checks))
            }
            let code = MeanwhileCore.Doctor.exitCode(checks)
            if code != 0 { throw ExitCode(code) }
        }

        static func checks(model: Bool) -> [MeanwhileCore.Doctor.Check] {
            typealias D = MeanwhileCore.Doctor
            let environment = ProcessInfo.processInfo.environment
            let path = environment["PATH"] ?? ""
            let uid = getuid()
            var checks: [D.Check] = []

            checks.append(D.system(version: ProcessInfo.processInfo.operatingSystemVersion, architecture: D.architecture))

            // Installed copies, and whether this build is the one installed.
            let installedApp = Binaries.installedApp
            var installedVersion: String?
            var sameBuild: Bool?
            if FileManager.default.isExecutableFile(atPath: installedApp.path) {
                let result = try? Shell.run(installedApp.path, ["--version"], timeout: 10, maximumOutputBytes: 4096)
                installedVersion = result.flatMap { $0.succeeded ? $0.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
                if let running = Bundle.main.executableURL?.resolvingSymlinksInPath(),
                   running.path != installedApp.resolvingSymlinksInPath().path {
                    sameBuild = FileManager.default.contentsEqual(atPath: running.path, andPath: installedApp.path)
                }
            }
            checks += D.binaries(directory: Binaries.directory, runningVersion: Meanwhile.version,
                                 installedVersion: installedVersion, sameBuild: sameBuild)
            checks.append(D.onPath(path, installed: installedApp))

            // Login item.
            let agent = LaunchAgent(executable: installedApp.path)
            let launch = (try? Shell.run("/bin/launchctl", ["print", "gui/\(uid)/\(LaunchAgent.label)"], timeout: 10))
                .map { D.LaunchStatus(launchctlStatus: $0.status, output: $0.text) }
                ?? D.LaunchStatus(loaded: false, running: false)
            checks += D.loginItem(plist: agent.plistURL, launch: launch, uid: uid)

            // Socket: connect and close without sending a line, so the app stores nothing.
            let answers = UnixSocket.send(Data(), to: MeanwhilePaths.socket.path)
            checks.append(D.socket(path: MeanwhilePaths.socket.path, answers: answers, uid: uid))
            checks.append(D.spool(backlog: D.spoolBacklog(directory: MeanwhilePaths.spool), appAnswers: answers, uid: uid))

            // Hooks.
            for hookAgent in HookInstaller.Agent.allCases {
                let scan = D.scanHooks(hookAgent, home: FileManager.default.homeDirectoryForCurrentUser)
                checks.append(D.hooks(hookAgent, scan: scan))
                if hookAgent == .codex, !scan.events.isEmpty { checks.append(D.codexTrustReminder) }
            }

            // Provider.
            let provider = D.configuredProvider()
            let cli = D.which(provider, path: path)
            checks.append(D.providerCLI(provider, path: cli))
            if cli != nil {
                checks.append(D.checkProviderLogin(provider))
                if model { checks.append(D.modelCall(Providers.configured())) }
            }

            // Databases, read-only.
            let registered = D.registeredMigrations()
            for url in [MeanwhilePaths.eventStore, MeanwhilePaths.reviewStore, MeanwhilePaths.libraryStore] {
                checks.append(D.database(D.inspectDatabase(url), registered: registered[url.lastPathComponent], uid: uid))
            }

            checks.append(D.config(UserSettings.defaultURL))

            // Repos and today's model calls.
            if FileManager.default.fileExists(atPath: MeanwhilePaths.libraryStore.path) {
                do {
                    let summary = try D.librarySummary(MeanwhilePaths.libraryStore)
                    checks.append(D.repos(summary))
                    checks.append(D.budget(callsToday: summary.callsToday))
                } catch {
                    checks.append(D.Check("repos", .warning, "Couldn't read repos from library.sqlite: \(error)"))
                }
            } else {
                checks.append(D.Check("repos", .ok, "No repos yet; send your agent a prompt in a repo"))
            }

            checks.append(D.log(agent.logURL))
            return checks
        }
    }
}
