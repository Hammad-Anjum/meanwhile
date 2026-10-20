import Foundation

/// The user's settings, in `~/.config/meanwhile/config.toml` (task 5.1, started with pacing).
///
/// The file is a flat `key = value` subset of TOML. Saving changes only the lines for the
/// settings it knows and keeps everything else, comments included.
public struct UserSettings: Sendable, Equatable {
    /// What the question cap counts over.
    public enum CapScope: String, Sendable, CaseIterable {
        case turn, day
    }

    /// Questions shown back to back in one round.
    public var questionsPerRound = 3
    /// From one round's start to the next. The first round starts with the agent's turn.
    public var roundInterval: TimeInterval = 120
    /// Most questions per `capScope`; nil means no cap. Predictions don't count.
    public var maxQuestions: Int? = 20
    public var capScope = CapScope.turn

    public init() {}

    // MARK: Keys

    public struct Key: Sendable {
        public let name: String
        public let help: String
    }

    public static let keys = [
        Key(name: "questions_per_round", help: "questions shown back to back in one round (1–20)"),
        Key(name: "round_interval", help: "time between rounds, e.g. 90s or 2m (10s–2h); the first round starts right away"),
        Key(name: "max_questions", help: "most questions per max_questions_per (1–1000, or none)"),
        Key(name: "max_questions_per", help: "what the cap counts over: turn (one agent run) or day"),
    ]

    public func value(of key: String) -> String? {
        switch key {
        case "questions_per_round": "\(questionsPerRound)"
        case "round_interval": Self.format(roundInterval)
        case "max_questions": maxQuestions.map(String.init) ?? "none"
        case "max_questions_per": capScope.rawValue
        default: nil
        }
    }

    /// Sets `key` from text as typed in the menu or on the command line.
    public mutating func set(_ key: String, to text: String) throws {
        let value = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        switch key {
        case "questions_per_round":
            guard let number = Int(value), (1...20).contains(number) else { throw SettingsError.invalid(key, "a whole number from 1 to 20") }
            questionsPerRound = number
        case "round_interval":
            guard let seconds = Self.parseDuration(value), (10...7_200).contains(seconds) else {
                throw SettingsError.invalid(key, "a time from 10s to 2h, like 90s or 2m")
            }
            roundInterval = seconds
        case "max_questions":
            if ["none", "off", "0", "unlimited", "no limit"].contains(value.lowercased()) {
                maxQuestions = nil
            } else {
                guard let number = Int(value), (1...1_000).contains(number) else {
                    throw SettingsError.invalid(key, "a whole number from 1 to 1000, or none")
                }
                maxQuestions = number
            }
        case "max_questions_per":
            guard let scope = CapScope(rawValue: value.lowercased()) else { throw SettingsError.invalid(key, "turn or day") }
            capScope = scope
        default:
            throw SettingsError.unknownKey(key)
        }
    }

    // MARK: Pacing

    /// When the next round starts, for a round that ended (or found nothing) at `now`:
    /// the first interval boundary after `now`, counted from the turn's start.
    public func nextRound(after now: Date, turnStarted: Date) -> Date {
        let elapsed = max(0, now.timeIntervalSince(turnStarted))
        let rounds = (elapsed / roundInterval).rounded(.down) + 1
        return turnStarted.addingTimeInterval(rounds * roundInterval)
    }

    /// Whether the cap is reached, given the questions shown this turn and today.
    public func capReached(thisTurn: Int, today: Int) -> Bool {
        guard let maxQuestions else { return false }
        return (capScope == .turn ? thisTurn : today) >= maxQuestions
    }

    /// "this turn" or "today", for the notch.
    public var capScopeText: String { capScope == .turn ? "this turn" : "today" }

    // MARK: File

    public static var defaultURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("meanwhile/config.toml")
    }

    /// The settings in `url`; defaults for a missing file and for any value that doesn't parse.
    public static func load(from url: URL = defaultURL) -> UserSettings {
        var settings = UserSettings()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return settings }
        for (key, value) in parse(text) where keys.contains(where: { $0.name == key }) {
            try? settings.set(key, to: value)
        }
        return settings
    }

    public func save(to url: URL = defaultURL) throws {
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? Self.header)
            .components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for key in Self.keys {
            let line = "\(key.name) = \(Self.tomlValue(key.name, value(of: key.name) ?? ""))"
            if let index = lines.firstIndex(where: { Self.keyOf($0) == key.name }) {
                lines[index] = line
            } else {
                lines.append(line)
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static let header = """
        # Meanwhile settings. Change them here, with `meanwhile config`, or from the menu bar icon.
        # A round of questions starts with each agent turn, then one every round_interval.

        """

    static func parse(_ text: String) -> [(String, String)] {
        text.components(separatedBy: .newlines).compactMap { line in
            guard let key = keyOf(line), let equals = line.firstIndex(of: "=") else { return nil }
            var value = String(line[line.index(after: equals)...])
            // A trailing comment, outside quotes.
            if let hash = value.firstIndex(of: "#"), value[..<hash].filter({ $0 == "\"" }).count % 2 == 0 {
                value = String(value[..<hash])
            }
            return (key, value.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func keyOf(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("["), let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    private static func tomlValue(_ key: String, _ value: String) -> String {
        Int(value) != nil ? value : "\"\(value)\""
    }

    /// "90", "90s", "2m", "1.5m", "1h" → seconds.
    static func parseDuration(_ text: String) -> TimeInterval? {
        let lower = text.lowercased().replacingOccurrences(of: " ", with: "")
        let units: [(String, Double)] = [("min", 60), ("m", 60), ("h", 3_600), ("s", 1)]
        for (suffix, factor) in units where lower.hasSuffix(suffix) {
            return Double(lower.dropLast(suffix.count)).map { $0 * factor }
        }
        return Double(lower)
    }

    /// 120 → "2m", 90 → "90s", 5400 → "90m".
    static func format(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return whole % 60 == 0 ? "\(whole / 60)m" : "\(whole)s"
    }
}

public enum SettingsError: Error, CustomStringConvertible, Equatable {
    case unknownKey(String)
    case invalid(String, String)

    public var description: String {
        switch self {
        case .unknownKey(let key):
            "No setting called \(key). Settings: \(UserSettings.keys.map(\.name).joined(separator: ", "))."
        case .invalid(let key, let expected):
            "\(key) must be \(expected)."
        }
    }
}
