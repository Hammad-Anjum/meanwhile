import Foundation

/// A deck of questions, loaded from one JSON file (format v1, see docs/packs.md).
public struct Pack: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        /// A topic deck, on for every repo unless turned off.
        case generic
        /// Follows the repo: shown only when the repo uses one of `stacks`.
        case stack
    }

    public struct Topic: Sendable, Equatable, Codable {
        public let id: String
        public let title: String
    }

    public let format: Int
    public let id: String
    public let title: String
    public let description: String
    public let kind: Kind
    public let stacks: [Stack]
    public let topics: [Topic]
    public let cards: [Card]

    /// Notch limits. Longer text doesn't fit the expanded notch.
    public static let maximumQuestion = 120
    public static let maximumOption = 50
    public static let maximumExplanation = 220

    /// Everything wrong with the pack, as readable lines. Empty means valid.
    public func problems() -> [String] {
        var problems: [String] = []
        if format != 1 { problems.append("format \(format) is not 1") }
        if kind == .stack, stacks.isEmpty { problems.append("stack pack lists no stacks") }
        if kind == .generic, !stacks.isEmpty { problems.append("generic pack lists stacks") }
        if cards.isEmpty { problems.append("no cards") }
        let topicIDs = Set(topics.map(\.id))
        var cardIDs = Set<String>()
        for card in cards {
            let label = card.id
            if !cardIDs.insert(card.id).inserted { problems.append("\(label): duplicate id") }
            if !topicIDs.contains(card.topic) { problems.append("\(label): unknown topic \(card.topic)") }
            if card.question.isEmpty || card.question.count > Self.maximumQuestion { problems.append("\(label): question length") }
            if card.explanation.isEmpty || card.explanation.count > Self.maximumExplanation { problems.append("\(label): explanation length") }
            switch (card.type, card.answer) {
            case (.multipleChoice, .option(let index)):
                let options = card.options ?? []
                if options.count != 4 { problems.append("\(label): needs 4 options") }
                if Set(options).count != options.count { problems.append("\(label): duplicate options") }
                if options.contains(where: { $0.isEmpty || $0.count > Self.maximumOption }) { problems.append("\(label): option length") }
                if !options.indices.contains(index) { problems.append("\(label): answer out of range") }
            case (.trueFalse, .truth):
                break
            default:
                problems.append("\(label): answer doesn't match type \(card.type.rawValue)")
            }
        }
        return problems
    }
}

/// A tech stack Meanwhile can detect in a repo.
public enum Stack: String, Sendable, Codable, CaseIterable {
    case swift, typescript, javascript, react, python, go, rust
}

public struct Card: Sendable, Equatable, Codable, Identifiable {
    public enum CardType: String, Sendable, Codable {
        case multipleChoice, trueFalse
    }

    public enum Answer: Sendable, Equatable, Codable {
        case option(Int)
        case truth(Bool)

        // JSON `answer` is an option index or a boolean.
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let truth = try? container.decode(Bool.self) { self = .truth(truth) }
            else { self = .option(try container.decode(Int.self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .option(let index): try container.encode(index)
            case .truth(let truth): try container.encode(truth)
            }
        }
    }

    public let id: String
    public let topic: String
    public let type: CardType
    public let question: String
    public let options: [String]?
    public let answer: Answer
    public let explanation: String
    public let source: String?

    /// The answers to show, in order. True/false cards show "True", "False".
    public var choices: [String] {
        type == .trueFalse ? ["True", "False"] : options ?? []
    }

    /// Index into `choices` of the correct answer.
    public var correctChoice: Int {
        switch answer {
        case .option(let index): index
        case .truth(let truth): truth ? 0 : 1
        }
    }
}
