import Foundation
import Testing
@testable import MeanwhileCore

/// Task 2.8: selection v2's rules, score and reason line.

private let now = Date(timeIntervalSince1970: 3_000_000)
private let day: TimeInterval = 86_400

private func deckCard(_ id: String, deck: String = "llm") -> QuestionSelector.Candidate {
    .init(id: id, deck: deck, deckTitle: deck.uppercased())
}

private func codeQuestion(_ id: String, file: String = "Sources/App.swift", recency: Double = 1,
                          notMine: Double = 0.8, hotspot: Double = 0.5) -> QuestionSelector.Candidate {
    .init(id: id, deck: "codebase", deckTitle: "Your codebase", file: file,
          codeSignals: .init(recency: recency, hotspot: hotspot, notMine: notMine))
}

private func context(_ build: (inout QuestionSelector.Context) -> Void = { _ in }) -> QuestionSelector.Context {
    var context = QuestionSelector.Context()
    context.now = now
    build(&context)
    return context
}

private func due(_ id: String, overdueDays: Double, step: Int = 0) -> Review {
    let interval = Spacing.intervals[step]
    return Review(cardID: id, step: step, dueAt: now.addingTimeInterval(-overdueDays * day),
                  lastShown: now.addingTimeInterval(-overdueDays * day - interval), timesShown: 1, timesCorrect: 1)
}

@Test func dueReviewsComeBeforeNewDeckCards() {
    let pick = QuestionSelector().next(from: [deckCard("new"), deckCard("old")],
                                       context: context { $0.reviews = ["old": due("old", overdueDays: 0)] })
    #expect(pick?.candidate.id == "old")
}

@Test func moreOverdueWins() {
    let pick = QuestionSelector().next(from: [deckCard("a"), deckCard("b")], context: context {
        $0.reviews = ["a": due("a", overdueDays: 1), "b": due("b", overdueDays: 20)]
    })
    #expect(pick?.candidate.id == "b")
}

@Test func freshCodebaseQuestionsLeadWhenTheAgentChangedCode() {
    let candidates = [deckCard("old"), codeQuestion("code")]
    let pick = QuestionSelector().next(from: candidates, context: context {
        $0.reviews = ["old": due("old", overdueDays: 2)]
        $0.agentTouchedCode = true
    })
    #expect(pick?.candidate.id == "code")
    #expect(pick?.why == "Agent changed App.swift this session · you didn't write most of it")
}

@Test func atLeastOneCodebaseQuestionWhenTheAgentEdited() {
    // A sufficiently evidenced codebase question goes first even with weak relevance signals.
    let weak = codeQuestion("weak", recency: 0, notMine: 0, hotspot: 0)
    let strongDeck = deckCard("old")
    let ctx = context {
        $0.reviews = ["old": due("old", overdueDays: 30)]
        $0.agentTouchedCode = true
    }
    #expect(QuestionSelector().next(from: [strongDeck, weak], context: ctx)?.candidate.id == "weak")
    // Once one was asked, the normal score decides.
    var after = ctx
    after.askedThisWait = [weak]
    #expect(QuestionSelector().next(from: [strongDeck, weak], context: after)?.candidate.id == "old")
}

@Test func thinCodebaseQuestionIsNotForcedByAnEdit() {
    let thin = QuestionSelector.Candidate(id: "thin", deck: "codebase", deckTitle: "Your codebase",
                                          file: "A.swift", codeSignals: .init(recency: 0, hotspot: 0, notMine: 0),
                                          contextScore: 2)
    let dueDeck = deckCard("due", deck: "design")
    let pick = QuestionSelector().next(from: [thin, dueDeck], context: context {
        $0.agentTouchedCode = true
        $0.reviews = ["due": due("due", overdueDays: 10)]
    })
    #expect(pick?.candidate.id == "due")
}

@Test func neverTheSameDeckOrFileTwiceInARow() {
    let candidates = [deckCard("a1", deck: "llm"), deckCard("a2", deck: "llm"), deckCard("b1", deck: "design")]
    let pick = QuestionSelector().next(from: candidates, context: context { $0.askedThisWait = [deckCard("a0", deck: "llm")] })
    #expect(pick?.candidate.deck == "design")

    let files = [codeQuestion("x", file: "A.swift"), codeQuestion("y", file: "B.swift", recency: 0.1)]
    let next = QuestionSelector().next(from: files, context: context {
        $0.askedThisWait = [codeQuestion("w", file: "A.swift")]
    })
    #expect(next?.candidate.id == "y", "a weaker question about another file beats a second one on A.swift")
}

@Test func rulesRemoveCandidates() {
    let candidates = [deckCard("asked"), deckCard("skippy"), deckCard("recent"), deckCard("ok", deck: "design")]
    let pick = QuestionSelector().next(from: candidates, context: context {
        $0.askedThisWait = [deckCard("asked")]
        $0.recentSkips = ["skippy": 2]
        $0.reviews = ["recent": Review(cardID: "recent", step: 1, dueAt: now.addingTimeInterval(day),
                                       lastShown: now.addingTimeInterval(-60), timesShown: 1, timesCorrect: 1)]
    })
    #expect(pick?.candidate.id == "ok")
    #expect(QuestionSelector().next(from: candidates, context: context {
        $0.askedThisWait = (1...3).map { deckCard("q\($0)") }
    }) == nil, "limit per wait")
}

@Test func deckFitPrefersAnsweredDecks() {
    let pick = QuestionSelector().next(from: [deckCard("a", deck: "skipped"), deckCard("b", deck: "liked")], context: context {
        $0.deckStats = ["skipped": .init(answered: 1, skipped: 9), "liked": .init(answered: 9, skipped: 1)]
    })
    #expect(pick?.candidate.deck == "liked")
}

@Test func difficultyControllerShiftsTowardNewOrReview() {
    let candidates = [deckCard("new"), deckCard("rev", deck: "design")]
    // Barely due review vs new card: struggling users get the review, cruising users the new card.
    var review = due("rev", overdueDays: 0)
    review.lastShown = now.addingTimeInterval(-day * 0.5)
    let struggling = QuestionSelector().next(from: candidates, context: context {
        $0.reviews = ["rev": review]; $0.recentAccuracy = 0.6
    })
    #expect(struggling?.candidate.id == "rev")
}

@Test func recallFollowsThePowerCurve() {
    let review = Review(cardID: "c", step: 0, lastShown: now.addingTimeInterval(-day))
    #expect(abs(QuestionSelector.recall(review, now: now) - 0.9) < 0.001, "R = 0.9 after one interval")
    #expect(QuestionSelector.recall(review, now: now.addingTimeInterval(10 * day)) < 0.5)
}

@Test func reasonLines() {
    let ctx = context { $0.reviews = ["r": due("r", overdueDays: 3)] }
    #expect(QuestionSelector().next(from: [deckCard("r")], context: ctx)?.why == "Review: last seen 4 days ago")
    #expect(QuestionSelector().next(from: [deckCard("n")], context: context())?.why == "New card")
    let old = codeQuestion("o", file: "Sources/Store.swift", recency: 0.1, notMine: 0.2, hotspot: 0.9)
    #expect(QuestionSelector().next(from: [old], context: context())?.why == "About Store.swift · it changes often")
}

// MARK: - Shown log

@Test func shownLogFeedsTheSelector() throws {
    let store = try ReviewStore(path: nil)
    let a = try store.logShown(cardID: "a", deck: "llm", session: "s", why: "New card", terms: ["novelty": 0.1], at: now)
    try store.finishShown(a, outcome: .skipped, at: now.addingTimeInterval(3))
    let b = try store.logShown(cardID: "a", deck: "llm", session: "s", why: nil, terms: [:], at: now)
    try store.finishShown(b, outcome: .skipped, at: now)
    let c = try store.logShown(cardID: "c", deck: "design", session: "s", why: nil, terms: [:], at: now)
    try store.finishShown(c, outcome: .answered, at: now)
    try store.finishShown(c, outcome: .skipped, at: now)  // first outcome sticks

    #expect(try store.skips(since: now.addingTimeInterval(-day)) == ["a": 2])
    #expect(try store.deckStats(since: now.addingTimeInterval(-day)) == ["llm": .init(answered: 0, skipped: 2),
                                                                         "design": .init(answered: 1, skipped: 0)])
    #expect(try store.recentAccuracy() == nil, "not enough answers yet")
    for index in 0..<10 {
        try store.recordAnswer(cardID: "x\(index)", choice: 0, correct: index < 7, confidence: .fairlySure, session: nil, at: now)
    }
    #expect(try store.recentAccuracy() == 0.7)
}

@Test func reportingAfterAnswerVoidsLearningAndReusesShownRow() throws {
    let store = try ReviewStore(path: nil)
    let now = Date()
    let shown = try store.logShown(cardID: "bad", deck: "codebase", session: "s", why: nil, terms: [:], at: now)
    let answer = try store.recordAnswer(cardID: "bad", choice: 0, correct: true, confidence: .fairlySure,
                                        session: "s", at: now.addingTimeInterval(1))
    try store.finishShown(shown, outcome: .answered, at: now.addingTimeInterval(1))
    try store.discard(answer)
    try store.reportShown(shown, at: now.addingTimeInterval(2))

    #expect(try store.answerCount() == 0)
    #expect(try store.reviews()["bad"] == answer.before)
    let stats = try store.deckStats(since: now.addingTimeInterval(-1))
    #expect(stats["codebase"]?.answered == 0 && stats["codebase"]?.skipped == 0)
}
