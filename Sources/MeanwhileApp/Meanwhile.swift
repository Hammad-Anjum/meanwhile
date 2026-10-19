import ArgumentParser
import Foundation
import MeanwhileCore

/// The `meanwhile` command. Named `MeanwhileCommand` so it doesn't shadow `MeanwhileCore.Meanwhile`.
@main
struct MeanwhileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meanwhile",
        abstract: "Short questions in the notch while your coding agent works.",
        version: Meanwhile.version,
        subcommands: [Run.self, Setup.self, Uninstall.self, Repos.self, Work.self, Version.self],
        defaultSubcommand: Run.self
    )
}

extension MeanwhileCommand {
    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start the background notch process (menu bar icon, notch, event server)."
        )

        @Flag(help: "Open the Event Log window at launch.")
        var showLog = false

        func run() throws {
            // ArgumentParser calls run() synchronously from main(), so this is the main thread.
            let showLog = showLog
            MainActor.assumeIsolated { MenuBarApp.run(showLog: showLog) }
        }
    }

    /// Started by `meanwhile-hook`; see `Worker`. Hidden from help.
    struct Work: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Index a repo and generate questions (started by meanwhile-hook).", shouldDisplay: false)

        @Option var repo: String
        @Option var reason: String = Worker.Request.Reason.manual.rawValue
        @Option var agent: String?
        @Option var session: String?

        func run() throws {
            let worker = Worker(library: try LibraryStore())
            let processed = try worker.submit(Worker.Request(
                directory: repo, reason: Worker.Request.Reason(rawValue: reason) ?? .manual,
                agent: agent, session: session))
            if processed == 0 { print("Another worker is running; it will pick this up.") }
        }
    }

    /// What the worker knows about each repo it has seen.
    struct Repos: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the repos Meanwhile has seen.")

        func run() throws {
            let repos = try LibraryStore().repos()
            if repos.isEmpty { print("No repos yet. Send your agent a prompt in a repo.") }
            for repo in repos {
                let access = repo.accessError.map { "can't read: \($0)" } ?? repo.fileCount.map { "\($0) files" } ?? "not read yet"
                print("\(repo.root)  [\(repo.state.rawValue)]  \(access)")
            }
        }
    }

    struct Version: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the version.")
        func run() throws { print(Meanwhile.version) }
    }
}
