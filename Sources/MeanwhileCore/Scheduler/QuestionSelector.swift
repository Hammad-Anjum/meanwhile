import Foundation

/// Selection v2 (task 2.8; docs/phase2-plan.md §2): hard rules first, then one transparent
/// weighted score over deck cards and pooled codebase questions alike.
public struct QuestionSelector: Sendable {
    /// Something that could be asked, with what the score needs to know about it.
    public struct Candidate: Sendable, Equatable {
        public let id: String
        /// The deck key: a pack id, or "codebase". No two in a row from the same one.
        public let deck: String
        public let deckTitle: String
        /// The file a codebase question is about; nil for deck cards. No two in a row either.
        public let file: String?
        public let codeSignals: CodeSignals?

        public init(id: String, deck: String, deckTitle: String, file: String? = nil, codeSignals: CodeSignals? = nil) {
            self.id = id
            self.deck = deck
            self.deckTitle = deckTitle
            self.file = file
            self.codeSignals = codeSignals
        }

        public var isCodebase: Bool { codeSignals != nil }
    }

    /// What makes a codebase question relevant now, each 0–1.
    public struct CodeSignals: Sendable, Equatable {
        /// 1 when the agent touched the file this session; halves each day since the question was made.
        public var recency: Double
        /// How much other code depends on the file. Neutral until the symbols index (task 2.11).
        public var centrality: Double
        /// How often the file changes relative to the repo's busiest file.
        public var hotspot: Double
        /// Share of the file's recent commits that weren't the user's.
        public var notMine: Double

        public init(recency: Double, centrality: Double = 0.5, hotspot: Double, notMine: Double) {
            self.recency = recency
            self.centrality = centrality
            self.hotspot = hotspot
            self.notMine = notMine
        }

        var relevance: Double { 0.35 * recency + 0.25 * centrality + 0.20 * hotspot + 0.20 * notMine }
    }

    /// How a deck's questions have been received lately.
    public struct DeckStats: Sendable, Equatable {
        public var answered: Int
        public var skipped: Int
        public init(answered: Int, skipped: Int) {
            self.answered = answered
            self.skipped = skipped
        }
        /// Beta(1+answered, 1+skipped) mean: 0.5 with no data.
        var fit: Double { Double(answered + 1) / Double(answered + skipped + 2) }
    }

    public struct Context: Sendable {
        public var reviews: [String: Review] = [:]
        public var deckStats: [String: DeckStats] = [:]
        /// Skips per question in the last 7 days.
        public var recentSkips: [String: Int] = [:]
        /// Reported as wrong: never shown again (task 2.10).
        public var suppressed: Set<String> = []
        public var askedThisWait: [Candidate] = []
        /// The agent edited code this turn: guarantees one codebase question if one fits.
        public var agentTouchedCode = false
        /// Share right over the last 20 answers; nil without enough data.
        public var recentAccuracy: Double?
        public var now = Date()
        public init() {}
    }

    public struct Selection: Sendable, Equatable {
        public let candidate: Candidate
        public let score: Double
        public let terms: [String: Double]
        /// One short line for the notch: why this question now.
        public let why: String
    }

    public var limitPerWait = 3
    /// A question seen this recently isn't repeated unless due.
    public var minimumGap: TimeInterval = 30 * 60

    public init() {}

    public func next(from candidates: [Candidate], context: Context) -> Selection? {
        guard context.askedThisWait.count < limitPerWait else { return nil }
        let asked = Set(context.askedThisWait.map(\.id))
        let previous = context.askedThisWait.last

        // 1. Rules that remove a candidate outright.
        var eligible = candidates.filter { candidate in
            guard !asked.contains(candidate.id), !context.suppressed.contains(candidate.id),
                  (context.recentSkips[candidate.id] ?? 0) < 2 else { return false }
            if let review = context.reviews[candidate.id], let shown = review.lastShown,
               context.now.timeIntervalSince(shown) < minimumGap, !isDue(review, context.now) { return false }
            return true
        }
        // Interleave: not the same deck or file twice in a row. Prefer both different, then at
        // least a different file (codebase questions all share one deck), then anything.
        if let previous {
            let otherFile = eligible.filter { $0.file == nil || $0.file != previous.file }
            let mixed = otherFile.filter { $0.deck != previous.deck }
            if !mixed.isEmpty { eligible = mixed } else if !otherFile.isEmpty { eligible = otherFile }
        }
        // The product's point: when the agent changed code, ask about it at least once.
        if context.agentTouchedCode, !context.askedThisWait.contains(where: \.isCodebase) {
            let codebase = eligible.filter(\.isCodebase)
            if !codebase.isEmpty { eligible = codebase }
        }

        // 2. One score, highest wins.
        return eligible.map { score($0, context) }.max { $0.score < $1.score }
    }

    func score(_ candidate: Candidate, _ context: Context) -> Selection {
        let review = context.reviews[candidate.id]
        let need: Double
        if let review, review.step != nil {
            let recall = Self.recall(review, now: context.now)
            if isDue(review, context.now) {
                // Due: at least 0.5, more the more overdue, so due reviews outrank new deck
                // cards (the 1.5 rule) while fresh codebase questions can still come first.
                need = max(1 - recall, 0.5)
            } else {
                // Not due: low; and well remembered is only filler.
                need = recall > 0.95 ? 0 : 1 - recall
            }
        } else {
            // Never answered: nothing to forget yet; Novelty carries it.
            need = 0
        }
        let relevance = candidate.codeSignals?.relevance ?? 0
        let fit = (context.deckStats[candidate.deck] ?? DeckStats(answered: 0, skipped: 0)).fit
        let novelty = review == nil ? 1.0 : 0.0

        // Difficulty controller: very accurate → more new material; struggling → more review.
        var weights = (need: 0.40, relevance: 0.35, fit: 0.15, novelty: 0.10)
        if let accuracy = context.recentAccuracy {
            if accuracy > 0.9 { weights.novelty += 0.10; weights.need -= 0.10 }
            if accuracy < 0.75 { weights.need += 0.10; weights.novelty -= 0.10 }
        }
        let terms = ["need": weights.need * need, "relevance": weights.relevance * relevance,
                     "fit": weights.fit * fit, "novelty": weights.novelty * novelty]
        let total = terms.values.reduce(0, +)
        return Selection(candidate: candidate, score: total, terms: terms, why: Self.why(candidate, terms, review, context.now))
    }

    func isDue(_ review: Review, _ now: Date) -> Bool { review.dueAt.map { $0 <= now } ?? false }

    /// FSRS's power forgetting curve with stability taken as the current interval:
    /// R = (1 + t / (9 S))^-1.
    static func recall(_ review: Review, now: Date) -> Double {
        guard let shown = review.lastShown else { return 0 }
        let stability = Spacing.intervals[min(review.step ?? 0, Spacing.intervals.count - 1)] / 86_400
        let elapsed = max(0, now.timeIntervalSince(shown) / 86_400)
        return 1 / (1 + elapsed / (9 * stability))
    }

    /// The reason line, from the biggest score terms.
    static func why(_ candidate: Candidate, _ terms: [String: Double], _ review: Review?, _ now: Date) -> String {
        var parts: [String] = []
        if let signals = candidate.codeSignals, let file = candidate.file {
            let name = (file as NSString).lastPathComponent
            if signals.recency >= 0.99 { parts.append("Agent changed \(name) this session") }
            else if signals.recency > 0.3 { parts.append("About \(name), changed recently") }
            else { parts.append("About \(name)") }
            if signals.notMine >= 0.6 { parts.append("you didn't write most of it") }
            else if signals.hotspot >= 0.6 { parts.append("it changes often") }
        } else if let review, let shown = review.lastShown, (terms["need"] ?? 0) >= 0.15 {
            let days = Int(now.timeIntervalSince(shown) / 86_400)
            parts.append(days <= 0 ? "Review: missed earlier" : "Review: last seen \(days) day\(days == 1 ? "" : "s") ago")
        } else if review == nil {
            parts.append("New card")
        } else {
            parts.append("Keeping it fresh")
        }
        return parts.joined(separator: " · ")
    }
}
