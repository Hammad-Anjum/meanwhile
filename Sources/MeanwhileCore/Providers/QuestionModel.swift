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
        var environment = ProcessInfo.processInfo.environment
        environment[Wire.internalCallVariable] = "1"
        return environment
    }

    /// An empty folder per call, so the CLI reads no repo instructions (AGENTS.md, CLAUDE.md).
    static func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meanwhile-call-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
        try JSONSerialization.data(withJSONObject: schema).write(to: schemaFile)

        let result = try Shell.run(executable, [
            "exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
            "--output-schema", schemaFile.path, "-o", answerFile.path, prompt,
        ], in: directory.path, environment: CLICall.environment, timeout: timeout)
        if result.timedOut { throw ModelError.timedOut(timeout) }
        guard result.succeeded else {
            if result.status == 127 { throw ModelError.notInstalled(executable) }
            throw ModelError.failed(String(result.stderr.suffix(300)))
        }
        guard let answer = try? Data(contentsOf: answerFile) else { throw ModelError.badOutput("no answer file") }
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
            "-p", prompt, "--output-format", "json", "--json-schema", schemaText,
            "--tools", "", "--no-session-persistence", "--model", model,
        ], in: directory.path, environment: CLICall.environment, timeout: timeout)
        if result.timedOut { throw ModelError.timedOut(timeout) }
        if result.status == 127 { throw ModelError.notInstalled(executable) }
        guard let envelope = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
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
