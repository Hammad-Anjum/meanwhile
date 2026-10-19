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
        case badType
        case badSource
        case answerInQuestion
        case duplicate

        public var description: String {
            switch self {
            case .tooLong(let field): "\(field) too long for the notch"
            case .badOptions: "needs 4 distinct options (or True/False)"
            case .badAnswer: "the correct answer is out of range"
            case .quoteNotFound: "the quote isn't word for word in the evidence"
            case .quoteMissing: "no quote"
            case .badType: "unknown question type"
            case .badSource: "the quote does not come from the named source"
            case .answerInQuestion: "the question gives the answer away"
            case .duplicate: "already in the pool"
            }
        }
    }

    /// Problems with `draft` given the evidence it came from; empty means it may be pooled.
    public static func problems(_ draft: DraftQuestion, sources: [EvidencePack.Source],
                                transmittedText: String? = nil, existing: [String] = []) -> [Problem] {
        var problems: [Problem] = []
        if draft.question.isEmpty || draft.question.count > Pack.maximumQuestion { problems.append(.tooLong("question")) }
        if draft.explanation.isEmpty || draft.explanation.count > Pack.maximumExplanation { problems.append(.tooLong("explanation")) }
        if draft.options.contains(where: { $0.isEmpty || $0.count > Pack.maximumOption }) { problems.append(.tooLong("option")) }
        if draft.quote.count > 160 { problems.append(.tooLong("quote")) }
        if draft.sourcePath.isEmpty || draft.sourcePath.count > 500 { problems.append(.tooLong("source path")) }
        let topicWords = draft.topic.split(whereSeparator: \Character.isWhitespace)
        if draft.topic.isEmpty || draft.topic.count > 50 || !(1...3).contains(topicWords.count) { problems.append(.tooLong("topic")) }

        switch draft.type {
        case "trueFalse":
            if draft.options.map({ $0.lowercased() }) != ["true", "false"] { problems.append(.badOptions) }
            if !(0...1).contains(draft.correct) { problems.append(.badAnswer) }
        case "multipleChoice":
            let distinct = Set(draft.options.map { normalize($0) })
            if draft.options.count != 4 || distinct.count != 4 { problems.append(.badOptions) }
            if !draft.options.indices.contains(draft.correct) { problems.append(.badAnswer) }
        default:
            problems.append(.badType)
        }

        let quote = quoteTokens(draft.quote)
        if quote.joined().count < 8 {
            problems.append(.quoteMissing)
        } else {
            let namedSources = sources.filter { $0.path == draft.sourcePath }
            if namedSources.isEmpty { problems.append(.badSource) }
            else if !namedSources.contains(where: { contains(quote, in: quoteTokens($0.text)) }) {
                problems.append(.quoteNotFound)
            }
            if let transmittedText, !transmittedText.isEmpty, !contains(quote, in: quoteTokens(transmittedText)) {
                problems.append(.quoteNotFound)
            }
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

    /// Whitespace-insensitive but operator-sensitive tokens. This accepts `x=1` vs `x = 1`
    /// while rejecting dangerous semantic substitutions such as `==` vs `!=` or `<` vs `>`.
    static func quoteTokens(_ text: String) -> [String] {
        var tokens: [String] = [], word = ""
        func flush() { if !word.isEmpty { tokens.append(word.lowercased()); word = "" } }
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                word.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flush()
            } else {
                flush()
                tokens.append(String(scalar))
            }
        }
        flush()
        return tokens
    }

    private static func contains(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<($0 + needle.count)]) == needle }
    }

    /// Word-set overlap (Jaccard), for near-duplicate stems.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Set(a.split(separator: " ")), y = Set(b.split(separator: " "))
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }
}
