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
        saved = [:]
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

    /// Saved answers by card, so a confidence picked later corrects the same answer.
    private var saved: [String: ReviewStore.RecordedAnswer] = [:]

    /// Saves an answer the moment it is given and returns when the card comes back. A right
    /// answer is saved as "fairly sure" until the user picks a confidence; a wrong answer
    /// starts over at one day either way.
    func record(_ question: QuizQuestion, _ answer: NotchModel.Answer) -> String {
        guard let id = question.cardID else { return "later" }
        if open == id { open = nil }
        guard let recorded = try? reviews?.recordAnswer(
            cardID: id, choice: answer.choice, correct: answer.correct,
            confidence: answer.correct ? .fairlySure : .guessed, session: session, at: Date()) else { return "later" }
        saved[id] = recorded
        return Spacing.comesBack(recorded.after, from: recorded.at)
    }

    /// Applies the confidence the user picked to the answer already saved for `question`.
    func revise(_ question: QuizQuestion, confidence: Confidence) -> String {
        guard let id = question.cardID, let recorded = saved[id],
              let revised = try? reviews?.revise(recorded, confidence: confidence) else { return "later" }
        saved[id] = revised
        return Spacing.comesBack(revised.after, from: revised.at)
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
