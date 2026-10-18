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

        func run() throws {
            // ArgumentParser calls run() synchronously from main(), so this is the main thread.
            MainActor.assumeIsolated { MenuBarApp.run() }
        }
    }

    struct Setup: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install the agent hooks.")
        func run() throws { throw notImplemented("setup") }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove the agent hooks.")
        func run() throws { throw notImplemented("uninstall") }
    }

    struct Version: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the version.")
        func run() throws { print(Meanwhile.version) }
    }
}

/// Prints to stderr and exits 1, without the usage text a `ValidationError` would add.
private func notImplemented(_ command: String) -> ExitCode {
    FileHandle.standardError.write(Data("meanwhile \(command): not implemented yet (task 1.7)\n".utf8))
    return .failure
}
