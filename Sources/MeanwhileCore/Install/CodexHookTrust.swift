import Foundation

/// Whether Codex will run Meanwhile's hooks. Codex skips new or changed hooks until the user
/// trusts them with `/hooks`, and records that in ~/.codex/config.toml as
///
///     [hooks.state."/Users/me/.codex/hooks.json:post_tool_use:0:0"]
///     trusted_hash = "sha256:..."
///
/// keyed by hooks file, event, group index and handler index (codex-rs/hooks, `hook_key`,
/// checked against codex-cli 0.163.0). Only reads that file; trust is the user's to give.
/// The hash is Codex's own fingerprint of the entry and isn't recomputed here, so an entry
/// edited after it was trusted still reads as trusted (Codex calls that "modified").
public struct CodexHookTrust: Sendable {
    public enum Status: Sendable, Equatable {
        /// No Meanwhile hooks in ~/.codex/hooks.json.
        case noHooks
        case trusted
        /// Events whose Meanwhile hook Codex hasn't been told to trust, or that are turned off.
        case untrusted([String])
    }

    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    var hooksFile: URL { home.appendingPathComponent(".codex/hooks.json") }
    var configFile: URL { home.appendingPathComponent(".codex/config.toml") }

    public func check() -> Status {
        let keys = stateKeys()
        guard !keys.isEmpty else { return .noHooks }
        let config = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        let trusted = Self.trustedKeys(in: config, among: keys.map(\.key))
        let missing = keys.filter { !trusted.contains($0.key) }.map(\.event)
        return missing.isEmpty ? .trusted : .untrusted(Array(Set(missing)).sorted())
    }

    /// The config-state key of every Meanwhile handler in hooks.json, with its event.
    func stateKeys() -> [(event: String, key: String)] {
        guard let data = try? Data(contentsOf: hooksFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any] else { return [] }
        var keys: [(event: String, key: String)] = []
        for (event, value) in hooks {
            for (groupIndex, group) in (value as? [[String: Any]] ?? []).enumerated() {
                for (handlerIndex, handler) in (group["hooks"] as? [[String: Any]] ?? []).enumerated()
                where (handler["command"] as? String)?.contains(HookInstaller.marker) == true {
                    let key = "\(hooksFile.path):\(Self.snakeCase(event)):\(groupIndex):\(handlerIndex)"
                    keys.append((event, key))
                }
            }
        }
        return keys
    }

    /// The keys among `keys` that have a `trusted_hash` and aren't `enabled = false`. Reads
    /// both the table form above and the inline `"key" = { trusted_hash = ... }` form.
    static func trustedKeys(in config: String, among keys: [String]) -> Set<String> {
        var trusted = Set<String>()
        var disabled = Set<String>()
        var table: String?
        for rawLine in config.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = keys.first { line == "[hooks.state.\"\($0)\"]" }
                continue
            }
            let key = table ?? keys.first { line.contains("\"\($0)\"") }
            guard let key else { continue }
            let compact = line.replacingOccurrences(of: " ", with: "")
            if compact.contains("trusted_hash=\"") { trusted.insert(key) }
            if compact.contains("enabled=false") { disabled.insert(key) }
        }
        return trusted.subtracting(disabled)
    }

    /// "PostToolUse" -> "post_tool_use", as Codex names events in its keys.
    static func snakeCase(_ event: String) -> String {
        event.enumerated().map { index, character in
            character.isUppercase ? (index == 0 ? "" : "_") + character.lowercased() : String(character)
        }.joined()
    }
}
