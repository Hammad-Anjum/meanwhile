import ArgumentParser
import Foundation
import MeanwhileCore

extension MeanwhileCommand {
    /// `meanwhile update`: installs the latest GitHub release over this one.
    /// Downloads the release tarball, checks it against SHA256SUMS, and runs the new
    /// binary's `setup --yes`, which replaces the installed copy and restarts the login item.
    struct Update: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update Meanwhile to the latest release.")

        /// Set to 1 to download and verify but not run setup (for testing).
        static let skipSetupVariable = "MEANWHILE_SKIP_SETUP"

        @Flag(help: "Only report whether an update is available.")
        var check = false

        @Flag(help: "Reinstall even if this version is the latest.")
        var force = false

        @Flag(help: .hidden)
        var skipSetup = false

        func run() throws {
            let environment = ProcessInfo.processInfo.environment
            let source = ReleaseSource(environment: environment)
            guard let current = SemanticVersion(Meanwhile.version) else {
                throw UpdateError("This build's version '\(Meanwhile.version)' isn't a release version.")
            }
            let latest = try ReleaseSource.latestVersion(fromJSON: try Download.data(from: source.latestURL))
            guard latest > current || force else {
                print("Meanwhile \(current) is up to date (latest release: \(latest)).")
                return
            }
            print(latest > current ? "Meanwhile \(latest) is available (you have \(current))." : "Reinstalling \(latest).")
            if check {
                if latest > current { print("Run `meanwhile update` to install it.") }
                return
            }

            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("meanwhile-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }

            print("Downloading \(source.tarballURL(latest).absoluteString)")
            let tarball = try Download.data(from: source.tarballURL(latest))
            let sums = Checksums(String(decoding: try Download.data(from: source.checksumsURL(latest)), as: UTF8.self))
            try sums.verify(tarball, name: ReleaseSource.tarballName(latest))
            print("✓ SHA-256 matches")

            let archive = work.appendingPathComponent(ReleaseSource.tarballName(latest))
            try tarball.write(to: archive)
            try Update.runTool("/usr/bin/tar", ["-xzf", archive.path, "-C", work.path])
            let newBinary = work.appendingPathComponent(ReleaseSource.folderName(latest)).appendingPathComponent("meanwhile")
            guard FileManager.default.isExecutableFile(atPath: newBinary.path) else {
                throw UpdateError("The release has no meanwhile binary at \(ReleaseSource.folderName(latest))/meanwhile.")
            }

            if skipSetup || environment[Update.skipSetupVariable] == "1" {
                try Update.runTool(newBinary.path, ["--version"])
                print("Skipped setup. Nothing installed.")
                return
            }
            try Update.runTool(newBinary.path, ["setup", "--yes"])
            print("✓ Updated to \(latest).")
        }

        /// Runs a tool with this process's terminal, and throws if it fails.
        static func runTool(_ path: String, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            fflush(stdout)
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw UpdateError("\((path as NSString).lastPathComponent) \(arguments.first ?? "") failed (exit \(process.terminationStatus)).")
            }
        }
    }
}

struct UpdateError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Blocking downloads for the CLI. Commands run synchronously from main().
enum Download {
    private final class Box: @unchecked Sendable {
        var result: Result<Data, Error> = .failure(URLError(.unknown))
    }

    static func data(from url: URL) throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("meanwhile/\(Meanwhile.version)", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                box.result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                box.result = .failure(UpdateError("\(url.absoluteString) answered HTTP \(http.statusCode)."
                    + (http.statusCode == 404 ? " Is there a published release?" : "")))
            } else {
                box.result = .success(data ?? Data())
            }
            done.signal()
        }.resume()
        done.wait()
        return try box.result.get()
    }
}
