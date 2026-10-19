import Foundation

/// What Meanwhile remembers about one card. A card with no review has never been shown.
public struct Review: Sendable, Equatable, Codable {
    public var cardID: String
    /// Index into `Spacing.intervals`; nil until the card is first answered.
    public var step: Int?
    public var dueAt: Date?
    public var lastShown: Date?
    public var timesShown: Int
    public var timesCorrect: Int

    public init(cardID: String, step: Int? = nil, dueAt: Date? = nil, lastShown: Date? = nil,
                timesShown: Int = 0, timesCorrect: Int = 0) {
        self.cardID = cardID
        self.step = step
        self.dueAt = dueAt
        self.lastShown = lastShown
        self.timesShown = timesShown
        self.timesCorrect = timesCorrect
    }
}

/// The v1 spacing rule from the plan: missed → tomorrow, then 2, 4, 7… days by confidence.
/// Keeps the same data a later FSRS scheduler would need (every answer is logged too).
public enum Spacing {
    public static let intervals: [TimeInterval] = [1, 2, 4, 7, 14, 30, 60].map { $0 * 24 * 3600 }

    /// The review after answering. A confident correct answer moves one interval up; a
    /// correct guess repeats the current interval; a miss starts over at one day.
    public static func answered(_ review: Review, correct: Bool, confident: Bool, at now: Date) -> Review {
        var next = review
        next.lastShown = now
        next.timesShown += 1
        if correct {
            next.timesCorrect += 1
            let current = review.step ?? 0
            next.step = review.step == nil
                ? (confident ? 1 : 0)
                : min(confident ? current + 1 : current, intervals.count - 1)
        } else {
            next.step = 0
        }
        next.dueAt = now.addingTimeInterval(intervals[next.step ?? 0])
        return next
    }

    /// Shown but not answered (skipped, or the agent finished first). Spacing unchanged.
    public static func shown(_ review: Review, at now: Date) -> Review {
        var next = review
        next.lastShown = now
        next.timesShown += 1
        return next
    }
}

/// A card ready to ask, with the deck it came from.
public struct ScheduledCard: Sendable, Equatable {
    public let card: Card
    public let pack: Pack.ID
    public let deckTitle: String
}

/// Picks the next card for a wait. Pure: give it the candidate packs, what is known about
/// each card, and what was already asked in this wait.
public struct Scheduler: Sendable {
    public var limitPerWait: Int
    /// A card seen this recently isn't repeated unless it is due.
    public var minimumGap: TimeInterval

    public init(limitPerWait: Int = 3, minimumGap: TimeInterval = 30 * 60) {
        self.limitPerWait = limitPerWait
        self.minimumGap = minimumGap
    }

    /// The next card, or nil when the wait's limit is reached or nothing is suitable.
    /// - Parameters:
    ///   - disabledTopics: `"<pack id>.<topic id>"` keys the user turned off.
    ///   - askedThisWait: cards already asked in this wait, oldest first.
    public func next<R: RandomNumberGenerator>(
        from packs: [Pack], reviews: [String: Review], disabledTopics: Set<String> = [],
        askedThisWait: [ScheduledCard], now: Date, using generator: inout R
    ) -> ScheduledCard? {
        guard askedThisWait.count < limitPerWait else { return nil }
        let asked = Set(askedThisWait.map(\.card.id))
        let candidates = packs.flatMap { pack in
            pack.cards
                .filter { !disabledTopics.contains("\(pack.id).\($0.topic)") && !asked.contains($0.id) }
                .map { ScheduledCard(card: $0, pack: pack.id, deckTitle: pack.title) }
        }

        // 1. Due cards, most overdue first.
        let due = candidates
            .compactMap { item in reviews[item.card.id]?.dueAt.flatMap { $0 <= now ? (item, $0) : nil } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        if let pick = interleaved(due, after: askedThisWait) { return pick }

        // 2. New cards, shuffled, spread across decks and topics.
        let fresh = candidates.filter { reviews[$0.card.id] == nil }.shuffled(using: &generator)
        if let pick = interleaved(fresh, after: askedThisWait) { return pick }

        // 3. Anything not seen recently, soonest due first.
        let rest = candidates
            .filter { item in
                guard let review = reviews[item.card.id] else { return false }
                return review.lastShown.map { now.timeIntervalSince($0) >= minimumGap } ?? true
            }
            .sorted { (reviews[$0.card.id]?.dueAt ?? .distantFuture) < (reviews[$1.card.id]?.dueAt ?? .distantFuture) }
        return interleaved(rest, after: askedThisWait)
    }

    /// Keeps the order's priority while mixing subjects: the first item from a deck not yet
    /// asked this wait, else from a deck other than the last one, else from another topic.
    private func interleaved(_ items: [ScheduledCard], after asked: [ScheduledCard]) -> ScheduledCard? {
        guard let previous = asked.last else { return items.first }
        let askedPacks = Set(asked.map(\.pack))
        return items.first { !askedPacks.contains($0.pack) }
            ?? items.first { $0.pack != previous.pack }
            ?? items.first { $0.card.topic != previous.card.topic }
            ?? items.first
    }
}

extension Scheduler {
    public func next(from packs: [Pack], reviews: [String: Review], disabledTopics: Set<String> = [],
                     askedThisWait: [ScheduledCard], now: Date) -> ScheduledCard? {
        var generator = SystemRandomNumberGenerator()
        return next(from: packs, reviews: reviews, disabledTopics: disabledTopics,
                    askedThisWait: askedThisWait, now: now, using: &generator)
    }
}
