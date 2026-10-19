import Foundation
import MeanwhileIPC

/// A model that turns a prompt into JSON matching a schema. Question generation (task 2.6)
/// only talks to this, so the agent CLIs and, later, API keys are interchangeable.
public protocol QuestionModel: Sendable {
    /// Short name for logs and the budget table, e.g. "codex".
    var name: String { get }
    /// Returns the model's JSON answer. `schema` is a JSON Schema object.
    func generate(prompt: String, schema: [String: Any]) throws -> Data
}

public enum ModelError: Error, CustomStringConvertible, Equatable {
    case notInstalled(String)
    case failed(String)
    case timedOut(TimeInterval)
    case badOutput(String)

    public var description: String {
        switch self {
        case .notInstalled(let name): "\(name) is not on your PATH"
        case .failed(let message): "the model call failed: \(message)"
        case .timedOut(let seconds): "the model call took longer than \(Int(seconds)) s"
        case .badOutput(let message): "the model's answer wasn't the expected JSON: \(message)"
        }
    }
}

/// Settings every CLI call shares.
enum CLICall {
    /// Meanwhile's own calls must not trigger Meanwhile's hooks (task 0.6).
    static var environment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        // The worker is launched from the user's terminal and may inherit cloud credentials,
        // dynamic-loader injection, and repo-specific variables. Provider CLIs need only their
        // login/config locations and ordinary process locale. USER is how the Claude CLI finds
        // its keychain login (without it: "Not logged in"); the API keys are each provider's own
        // key, passed to that provider's unmodified binary and never read here.
        let allowed = ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM",
                       "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR",
                       "ANTHROPIC_API_KEY", "OPENAI_API_KEY"]
        var environment = Dictionary(uniqueKeysWithValues: allowed.compactMap { key in
            inherited[key].map { (key, $0) }
        })
        if let path = environment["PATH"] {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
            environment["PATH"] = path.split(separator: ":").map(String.init).filter {
                $0.hasPrefix("/") && $0 != cwd && !$0.hasPrefix(cwd + "/")
            }.joined(separator: ":")
        }
        environment[Wire.internalCallVariable] = "1"
        return environment
    }

    /// An empty folder per call, so the CLI reads no repo instructions (AGENTS.md, CLAUDE.md).
    static func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meanwhile-call-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    static func ensureObject(_ data: Data) throws -> Data {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw ModelError.badOutput(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return data
    }
}

/// `codex exec`: the default provider, on the user's ChatGPT plan (decided 2026-10-19).
public struct CodexCLIModel: QuestionModel {
    public let name = "codex"
    let executable: String
    let timeout: TimeInterval

    public init(executable: String = "codex", timeout: TimeInterval = 90) {
        self.executable = executable
        self.timeout = timeout
    }

    public func generate(prompt: String, schema: [String: Any]) throws -> Data {
        let directory = try CLICall.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schemaFile = directory.appendingPathComponent("schema.json")
        let answerFile = directory.appendingPathComponent("answer.json")
        try JSONSerialization.data(withJSONObject: schema).write(to: schemaFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: schemaFile.path)

        let result = try Shell.run(executable, [
            "exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
            "--ignore-user-config", "--ignore-rules", "--disable", "shell_tool",
            "--output-schema", schemaFile.path, "-o", answerFile.path, "-",
        ], in: directory.path, environment: CLICall.environment, input: Data(prompt.utf8), timeout: timeout,
           maximumOutputBytes: 512 * 1024)
        if result.timedOut { throw ModelError.timedOut(timeout) }
        guard result.succeeded else {
            if result.status == 127 { throw ModelError.notInstalled(executable) }
            throw ModelError.failed(String(result.stderr.suffix(300)))
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: answerFile.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 256 * 1024,
              let answer = try? Data(contentsOf: answerFile) else { throw ModelError.badOutput("no or oversized answer file") }
        return try CLICall.ensureObject(answer)
    }
}

/// `claude -p`: the alternative provider. Runs the user's own unmodified binary, never
/// touching its login (docs/README.md, terms check).
public struct ClaudeCLIModel: QuestionModel {
    public let name = "claude"
    let executable: String
    let model: String
    let timeout: TimeInterval

    public init(executable: String = "claude", model: String = "haiku", timeout: TimeInterval = 90) {
        self.executable = executable
        self.model = model
        self.timeout = timeout
    }

    public func generate(prompt: String, schema: [String: Any]) throws -> Data {
        let directory = try CLICall.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schemaText = String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)
        let result = try Shell.run(executable, [
            "-p", "--output-format", "json", "--json-schema", schemaText,
            "--tools", "", "--no-session-persistence", "--model", model,
        ], in: directory.path, environment: CLICall.environment, input: Data(prompt.utf8), timeout: timeout,
           maximumOutputBytes: 512 * 1024)
        if result.timedOut { throw ModelError.timedOut(timeout) }
        if result.status == 127 { throw ModelError.notInstalled(executable) }
        guard result.stdout.count <= 256 * 1024,
              let envelope = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw ModelError.failed(String(result.stderr.suffix(300)))
        }
        if envelope["is_error"] as? Bool == true {
            throw ModelError.failed(String(describing: envelope["result"] ?? "error"))
        }
        guard let structured = envelope["structured_output"] as? [String: Any] else {
            throw ModelError.badOutput("no structured_output")
        }
        return try JSONSerialization.data(withJSONObject: structured)
    }
}

public enum Providers {
    public static let defaultsKey = "provider"

    /// The provider `meanwhile setup` chose, else codex (the default), else claude.
    public static func configured(defaults: UserDefaults = .standard) -> QuestionModel {
        switch defaults.string(forKey: defaultsKey) {
        case "claude": ClaudeCLIModel()
        default: CodexCLIModel()
        }
    }
}
