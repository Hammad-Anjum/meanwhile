import Foundation
import Testing
@testable import MeanwhileCore

/// Task 1.5: spacing and card selection.

private let now = Date(timeIntervalSince1970: 2_000_000)
private let day: TimeInterval = 24 * 3600

/// Deterministic generator so shuffles are repeatable.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func card(_ id: String, topic: String = "a") -> Card {
    Card(id: id, topic: topic, type: .trueFalse, question: "Q \(id)?", options: nil,
         answer: .truth(true), explanation: "e", source: nil)
}

private func pack(_ id: String, _ cards: [Card]) -> Pack {
    let topics = Set(cards.map(\.topic)).sorted().map { Pack.Topic(id: $0, title: $0) }
    return Pack(format: 1, id: id, title: id.uppercased(), description: "d", kind: .generic, stacks: [],
                topics: topics, cards: cards)
}

private func pick(_ packs: [Pack], _ reviews: [String: Review] = [:], asked: [ScheduledCard] = [],
                  disabled: Set<String> = [], scheduler: Scheduler = Scheduler(), seed: UInt64 = 1) -> ScheduledCard? {
    var generator = SplitMix64(state: seed)
    return scheduler.next(from: packs, reviews: reviews, disabledTopics: disabled, askedThisWait: asked,
                          now: now, using: &generator)
}

private func scheduled(_ id: String, pack: String, topic: String = "a") -> ScheduledCard {
    ScheduledCard(card: card(id, topic: topic), pack: pack, deckTitle: pack)
}

// MARK: - Spacing

@Test func firstAnswerSetsTheFirstInterval() {
    let fresh = Review(cardID: "c")
    let sure = Spacing.answered(fresh, correct: true, confidence: .fairlySure, at: now)
    #expect(sure.step == 1 && sure.dueAt == now.addingTimeInterval(2 * day))
    let knew = Spacing.answered(fresh, correct: true, confidence: .knewIt, at: now)
    #expect(knew.step == 2 && knew.dueAt == now.addingTimeInterval(4 * day))
    let guess = Spacing.answered(fresh, correct: true, confidence: .guessed, at: now)
    #expect(guess.step == 0 && guess.dueAt == now.addingTimeInterval(day))
    let miss = Spacing.answered(fresh, correct: false, confidence: .knewIt, at: now)
    #expect(miss.step == 0 && miss.dueAt == now.addingTimeInterval(day) && miss.timesCorrect == 0)
}

@Test func fairlySureAnswersClimbTwoFourSevenDays() {
    var review = Review(cardID: "c")
    var days: [Double] = []
    for _ in 0..<4 {
        review = Spacing.answered(review, correct: true, confidence: .fairlySure, at: now)
        days.append((review.dueAt!.timeIntervalSince(now) / day).rounded())
    }
    #expect(days == [2, 4, 7, 14])
    #expect(review.timesShown == 4 && review.timesCorrect == 4)
}

@Test func aGuessHoldsTheIntervalAndAMissStartsOver() {
    var review = Review(cardID: "c", step: 3)
    review = Spacing.answered(review, correct: true, confidence: .guessed, at: now)
    #expect(review.step == 3)
    review = Spacing.answered(review, correct: true, confidence: .knewIt, at: now)
    #expect(review.step == 5)
    review = Spacing.answered(review, correct: false, confidence: .knewIt, at: now)
    #expect(review.step == 0 && review.dueAt == now.addingTimeInterval(day))
}

@Test func intervalsStopAtSixtyDays() {
    let review = Spacing.answered(Review(cardID: "c", step: 6), correct: true, confidence: .knewIt, at: now)
    #expect(review.step == 6 && review.dueAt == now.addingTimeInterval(60 * day))
}

@Test func comesBackInWords() {
    #expect(Spacing.comesBack(Spacing.answered(Review(cardID: "c"), correct: false, confidence: .guessed, at: now), from: now) == "tomorrow")
    #expect(Spacing.comesBack(Spacing.answered(Review(cardID: "c"), correct: true, confidence: .knewIt, at: now), from: now) == "in 4 days")
}

@Test func shownWithoutAnswerKeepsSpacing() {
    let before = Review(cardID: "c", step: 2, dueAt: now, timesShown: 1)
    let after = Spacing.shown(before, at: now)
    #expect(after.step == 2 && after.dueAt == now && after.timesShown == 2 && after.lastShown == now)
}

// MARK: - Selection

@Test func stopsAtTheLimitPerWait() {
    let packs = [pack("p", (1...10).map { card("p.a.\($0)") })]
    let asked = (1...3).map { scheduled("p.a.\($0)", pack: "p") }
    #expect(pick(packs, asked: asked) == nil)
    #expect(pick(packs, asked: Array(asked.prefix(2))) != nil)
}

@Test func dueCardsComeBeforeNewOnesMostOverdueFirst() {
    let packs = [pack("p", (1...5).map { card("p.a.\($0)") })]
    let reviews = [
        "p.a.2": Review(cardID: "p.a.2", step: 0, dueAt: now.addingTimeInterval(-day), lastShown: now.addingTimeInterval(-2 * day)),
        "p.a.4": Review(cardID: "p.a.4", step: 0, dueAt: now.addingTimeInterval(-3 * day), lastShown: now.addingTimeInterval(-4 * day)),
        "p.a.5": Review(cardID: "p.a.5", step: 2, dueAt: now.addingTimeInterval(day)),
    ]
    #expect(pick(packs, reviews)?.card.id == "p.a.4")
}

@Test func newCardsAlternateDecks() {
    let packs = [pack("a", (1...5).map { card("a.a.\($0)") }), pack("b", (1...5).map { card("b.a.\($0)") })]
    for seed in 1...20 as ClosedRange<UInt64> {
        #expect(pick(packs, asked: [scheduled("a.a.1", pack: "a")], seed: seed)?.pack == "b")
    }
}

@Test func withOneDeckTopicsAlternate() {
    let cards = (1...4).map { card("p.x.\($0)", topic: "x") } + [card("p.y.1", topic: "y")]
    let packs = [pack("p", cards)]
    #expect(pick(packs, asked: [scheduled("p.x.1", pack: "p", topic: "x")])?.card.topic == "y")
}

@Test func disabledTopicsAndAskedCardsAreSkipped() {
    let packs = [pack("p", [card("p.x.1", topic: "x"), card("p.y.1", topic: "y"), card("p.y.2", topic: "y")])]
    let result = pick(packs, asked: [scheduled("p.y.1", pack: "p", topic: "y")], disabled: ["p.x"])
    #expect(result?.card.id == "p.y.2")
}

@Test func recentlySeenCardsWaitUnlessDue() {
    let packs = [pack("p", [card("p.a.1"), card("p.a.2")])]
    let recent = now.addingTimeInterval(-10 * 60)
    let reviews = [
        "p.a.1": Review(cardID: "p.a.1", step: 1, dueAt: now.addingTimeInterval(day), lastShown: recent),
        "p.a.2": Review(cardID: "p.a.2", step: 1, dueAt: now.addingTimeInterval(2 * day), lastShown: recent),
    ]
    #expect(pick(packs, reviews) == nil)

    var older = reviews
    older["p.a.2"]?.lastShown = now.addingTimeInterval(-2 * 3600)
    #expect(pick(packs, older)?.card.id == "p.a.2")

    var due = reviews
    due["p.a.1"]?.dueAt = now.addingTimeInterval(-60)
    #expect(pick(packs, due)?.card.id == "p.a.1")
}

@Test func nothingToAskFromNoPacks() {
    #expect(pick([]) == nil)
}

// MARK: - Store

@Test func reviewStoreRecordsAnswersAndShows() throws {
    let store = try ReviewStore(path: nil)
    try store.recordAnswer(cardID: "c1", choice: 0, correct: true, confidence: .fairlySure, session: "s", at: now)
    try store.recordAnswer(cardID: "c1", choice: nil, correct: false, confidence: .guessed, session: "s", at: now.addingTimeInterval(60))
    try store.recordShown(cardID: "c2", at: now)

    let reviews = try store.reviews()
    #expect(reviews["c1"]?.step == 0 && reviews["c1"]?.timesShown == 2 && reviews["c1"]?.timesCorrect == 1)
    #expect(reviews["c2"]?.step == nil && reviews["c2"]?.timesShown == 1)
    #expect(try store.answerCount() == 2)
}

/// A right answer is saved at the click as "fairly sure"; picking a confidence afterwards
/// corrects that same answer instead of adding one (seen 2026-10-19: answers were lost when
/// "needs you" interrupted before the confidence pick).
@Test func confidenceCanBeRevisedAfterSaving() throws {
    let store = try ReviewStore(path: nil)
    let saved = try store.recordAnswer(cardID: "c", choice: 0, correct: true, confidence: .fairlySure, session: nil, at: now)
    #expect(saved.after.step == 1)

    let knew = try store.revise(saved, confidence: .knewIt)
    #expect(knew.after.step == 2 && knew.after.dueAt == now.addingTimeInterval(4 * day))
    #expect(try store.reviews()["c"]?.step == 2)
    #expect(try store.reviews()["c"]?.timesShown == 1, "still one showing")
    #expect(try store.answerCount() == 1)
    #expect(try store.confidence(ofAnswer: saved.answerID) == .knewIt)

    try store.revise(knew, confidence: .guessed)
    #expect(try store.reviews()["c"]?.step == 0)
}

@Test func schedulerWorksOnTheBundledDecks() {
    let packs = PackLibrary.bundled().library.packs(disabled: [], stacks: [.swift])
    var asked: [ScheduledCard] = []
    while let next = pick(packs, asked: asked) { asked.append(next) }
    #expect(asked.count == 3)
    #expect(Set(asked.map(\.pack)).count == 3, "three different decks in one wait")
}
