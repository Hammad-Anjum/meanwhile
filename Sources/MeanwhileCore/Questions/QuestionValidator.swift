import Foundation

/// Deterministic checks every codebase question passes before it can show (task 2.7;
/// docs/question-engine.md "Validation"). A wrong question about your code costs more
/// trust than a right one earns, so anything doubtful is dropped.
public enum QuestionValidator {
    public enum Problem: Equatable, Sendable, CustomStringConvertible {
        case tooLong(String)
        case badOptions
        case badAnswer
        case quoteNotFound
        case quoteMissing
        case answerInQuestion
        case duplicate

        public var description: String {
            switch self {
            case .tooLong(let field): "\(field) too long for the notch"
            case .badOptions: "needs 4 distinct options (or True/False)"
            case .badAnswer: "the correct answer is out of range"
            case .quoteNotFound: "the quote isn't word for word in the evidence"
            case .quoteMissing: "no quote"
            case .answerInQuestion: "the question gives the answer away"
            case .duplicate: "already in the pool"
            }
        }
    }

    /// Problems with `draft` given the evidence it came from; empty means it may be pooled.
    public static func problems(_ draft: DraftQuestion, sources: [EvidencePack.Source],
                                existing: [String] = []) -> [Problem] {
        var problems: [Problem] = []
        if draft.question.isEmpty || draft.question.count > Pack.maximumQuestion { problems.append(.tooLong("question")) }
        if draft.explanation.isEmpty || draft.explanation.count > Pack.maximumExplanation { problems.append(.tooLong("explanation")) }
        if draft.options.contains(where: { $0.isEmpty || $0.count > Pack.maximumOption }) { problems.append(.tooLong("option")) }

        switch draft.type {
        case "trueFalse":
            if draft.options.map({ $0.lowercased() }) != ["true", "false"] { problems.append(.badOptions) }
            if !(0...1).contains(draft.correct) { problems.append(.badAnswer) }
        default:
            let distinct = Set(draft.options.map { normalize($0) })
            if draft.options.count != 4 || distinct.count != 4 { problems.append(.badOptions) }
            if !draft.options.indices.contains(draft.correct) { problems.append(.badAnswer) }
        }

        let quote = normalize(draft.quote)
        if quote.count < 8 {
            problems.append(.quoteMissing)
        } else if !sources.contains(where: { normalize($0.text).contains(quote) }) {
            problems.append(.quoteNotFound)
        }

        // A multiple-choice stem that contains its own correct option word for word.
        if draft.type != "trueFalse", draft.options.indices.contains(draft.correct) {
            let answer = normalize(draft.options[draft.correct])
            if answer.count > 3, normalize(draft.question).contains(answer) { problems.append(.answerInQuestion) }
        }

        let stem = normalize(draft.question)
        if existing.contains(where: { similarity(normalize($0), stem) > 0.8 }) { problems.append(.duplicate) }
        return problems
    }

    /// Lowercased, punctuation dropped, whitespace collapsed: so line breaks and quote
    /// marks in the evidence don't fail a real quote.
    static func normalize(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Word-set overlap (Jaccard), for near-duplicate stems.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Set(a.split(separator: " ")), y = Set(b.split(separator: " "))
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }
}
