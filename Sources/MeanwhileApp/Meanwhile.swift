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
        subcommands: [Run.self, Setup.self, Uninstall.self, Version.self],
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

    struct Version: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the version.")
        func run() throws { print(Meanwhile.version) }
    }
}
