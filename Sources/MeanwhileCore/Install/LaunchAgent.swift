import Foundation

/// The per-user launch agent that keeps `meanwhile run` going: started now and at login,
/// restarted after a crash, but left stopped when the user quits from the menu.
public struct LaunchAgent: Sendable {
    public static let label = "dev.meanwhile.agent"

    public let home: URL
    /// Absolute path of the `meanwhile` executable to run.
    public let executable: String

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, executable: String) {
        self.home = home
        self.executable = executable
    }

    public var plistURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    public var logURL: URL {
        home.appendingPathComponent("Library/Logs/Meanwhile/meanwhile.log")
    }

    public func plist() throws -> Data {
        let object: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executable, "run"],
            "RunAtLoad": true,
            // Quit from the menu exits 0 and stays quit; a crash restarts.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    /// Writes the plist and (re)loads it with launchctl.
    public func install() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try? Self.launchctl(["bootout", Self.serviceTarget])
        try plist().write(to: plistURL, options: .atomic)
        try Self.launchctl(["bootstrap", Self.domain, plistURL.path])
    }

    /// Stops the agent and removes the plist. Missing pieces are not an error.
    public func uninstall() throws {
        _ = try? Self.launchctl(["bootout", Self.serviceTarget])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static var domain: String { "gui/\(getuid())" }
    private static var serviceTarget: String { "\(domain)/\(label)" }

    @discardableResult
    private static func launchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw InstallError.launchctl("\(arguments.joined(separator: " ")): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }
}
