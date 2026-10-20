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
        subcommands: [Run.self, Setup.self, Uninstall.self, Repos.self, Config.self, Work.self, ModelCheck.self,
                      Generate.self, Version.self],
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

    /// One real model call with a sample prompt, timed. For checking a provider works.
    struct ModelCheck: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "model-check", abstract: "Ask the question model one sample question.", shouldDisplay: false)

        @Option(help: "codex or claude. Default: the configured provider.")
        var provider: String?

        func run() throws {
            let model: QuestionModel = switch provider {
            case "claude": ClaudeCLIModel()
            case "codex": CodexCLIModel()
            default: Providers.configured()
            }
            let schema: [String: Any] = [
                "type": "object", "additionalProperties": false,
                "required": ["question", "options", "correct"],
                "properties": [
                    "question": ["type": "string"],
                    "options": ["type": "array", "items": ["type": "string"], "minItems": 4, "maxItems": 4],
                    "correct": ["type": "integer", "minimum": 0, "maximum": 3],
                ],
            ]
            let start = Date()
            let answer = try model.generate(
                prompt: "Write one multiple-choice question (4 options, one correct) about what a SQLite WAL file is for.",
                schema: schema)
            print(String(decoding: answer, as: UTF8.self))
            print(String(format: "%@: %.1f s", model.name, Date().timeIntervalSince(start)))
        }
    }

    /// Runs the worker for one session's latest turn and prints the pool. For checking
    /// generation on a real repo without waiting for a turn to end.
    struct Generate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Generate codebase questions for a session's latest turn.", shouldDisplay: false)

        @Option var repo: String
        @Option var session: String
        @Option(help: "post-turn or live") var kind = "post-turn"
        @Flag(help: "Turn the repo on first.") var turnOn = false

        func run() throws {
            let library = try LibraryStore()
            let root = StackDetector.repoRoot(for: repo)
            if turnOn { try library.setState(.on, root: root) }
            let before = Set(try library.poolQuestions(root: root).map(\.id))
            let start = Date()
            try Worker(library: library, eventSettle: 0).submit(.init(
                directory: root, reason: kind == "live" ? .edit : .turnEnd, session: session))
            for question in try library.poolQuestions(root: root) where !before.contains(question.id) {
                print("[\(question.kind) · \(question.topic)] \(question.question)")
                for (index, option) in question.options.enumerated() {
                    print("   \(index == question.correct ? "✓" : " ") \(option)")
                }
                print("   quote: \(question.quote)  (\(question.sourcePath))")
            }
            if let card = try library.repoCard(root: root) { print("\nRepo card: \(card)") }
            print(String(format: "\n%.1f s · %d calls today", Date().timeIntervalSince(start),
                         try GenerationBudget(library: library).callsToday()))
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
                let worktree = repo.isWorktree ? "  worktree of \((repo.project as NSString).lastPathComponent)" : ""
                print("\(repo.root)  [\(repo.state.rawValue)]  \(access)\(worktree)")
            }
        }
    }

    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or change settings.",
            discussion: """
                meanwhile config                        show every setting
                meanwhile config questions_per_round 3  change one
                The app picks a change up at the next agent turn.
                """)

        @Argument(help: "The setting to change.")
        var key: String?

        @Argument(help: "Its new value.")
        var value: String?

        func run() throws {
            var settings = UserSettings.load()
            guard let key else {
                print("Settings in \(UserSettings.defaultURL.path):")
                for entry in UserSettings.keys {
                    print("  \(entry.name) = \(settings.value(of: entry.name) ?? "")    # \(entry.help)")
                }
                return
            }
            guard let value else {
                guard let current = settings.value(of: key) else { throw ValidationError(SettingsError.unknownKey(key).description) }
                print(current)
                return
            }
            do {
                try settings.set(key, to: value)
            } catch let error as SettingsError {
                throw ValidationError(error.description)
            }
            try settings.save()
            print("\(key) = \(settings.value(of: key) ?? value). The app uses it from the next agent turn.")
        }
    }

    struct Version: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the version.")
        func run() throws { print(Meanwhile.version) }
    }
}
