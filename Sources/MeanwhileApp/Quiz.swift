import Foundation
import MeanwhileCore

/// The questions for one agent wait: picks cards with the scheduler and records answers.
@MainActor
final class Quiz {
    private let decks: Decks
    private let reviews: ReviewStore?
    let scheduler = Scheduler()
    private var asked: [ScheduledCard] = []
    private var cwd = FileManager.default.currentDirectoryPath
    private var session: String?
    /// The card on screen and not yet answered or skipped.
    private var open: String?

    init(decks: Decks, reviews: ReviewStore?) {
        self.decks = decks
        self.reviews = reviews
    }

    /// Starts a new wait (an agent turn) in the repo at `cwd`.
    func startWait(session: String?, cwd: String) {
        endWait()
        asked = []
        self.session = session
        self.cwd = cwd
    }

    /// The next card for this wait, or nil when its limit is reached or nothing fits.
    func next() -> QuizQuestion? {
        let known = (try? reviews?.reviews()) ?? [:]
        let packs = decks.packs(forDirectory: cwd)
        guard let pick = scheduler.next(from: packs, reviews: known, askedThisWait: asked, now: Date()) else { return nil }
        asked.append(pick)
        open = pick.card.id
        let topic = packs.first { $0.id == pick.pack }?.topics.first { $0.id == pick.card.topic }?.title
        return QuizQuestion(card: pick.card, deck: pick.deckTitle, topic: topic)
    }

    /// Records an answer and returns when the card comes back. A wrong answer has no
    /// confidence; it starts over at one day either way.
    func record(_ question: QuizQuestion, _ answer: NotchModel.Answer, confidence: Confidence?) -> String {
        guard let id = question.cardID else { return "later" }
        if open == id { open = nil }
        let now = Date()
        guard let review = try? reviews?.recordAnswer(
            cardID: id, choice: answer.choice, correct: answer.correct,
            confidence: confidence ?? .guessed, session: session, at: now) else { return "later" }
        return Spacing.comesBack(review, from: now)
    }

    func skipped(_ question: QuizQuestion) {
        guard let id = question.cardID else { return }
        if open == id { open = nil }
        try? reviews?.recordShown(cardID: id)
    }

    /// Ends the wait. A question left unanswered counts as shown, without changing its spacing.
    func endWait() {
        if let id = open { try? reviews?.recordShown(cardID: id) }
        open = nil
    }

    /// The repo's folder name, for the notch's status line.
    func repoName(for cwd: String) -> String {
        (StackDetector.repoRoot(for: cwd) as NSString).lastPathComponent
    }
}
