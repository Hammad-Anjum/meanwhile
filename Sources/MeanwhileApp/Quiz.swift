import Foundation
import MeanwhileCore

/// The questions for one agent wait: picks cards with the scheduler and records answers.
@MainActor
final class Quiz {
    private let decks: Decks
    private let reviews: ReviewStore?
    private let scheduler = Scheduler()
    private var asked: [ScheduledCard] = []
    private var cwd = FileManager.default.currentDirectoryPath
    private var session: String?

    /// The question on screen and not yet answered; asked again after a needs-input pause.
    private(set) var current: SpikeQuestion?

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
    func next() -> SpikeQuestion? {
        let known = (try? reviews?.reviews()) ?? [:]
        guard let pick = scheduler.next(from: decks.packs(forDirectory: cwd), reviews: known,
                                        askedThisWait: asked, now: Date()) else { return nil }
        asked.append(pick)
        current = SpikeQuestion(card: pick.card, deck: pick.deckTitle)
        return current
    }

    /// Records an answer. Every correct answer counts as confident until the notch has
    /// confidence buttons (task 1.6).
    func answered(_ question: SpikeQuestion, choice: Int) {
        guard let id = question.cardID else { return }
        current = nil
        _ = try? reviews?.recordAnswer(cardID: id, choice: choice, correct: choice == question.correct,
                                       confident: true, session: session)
    }

    /// Ends the wait. A question left unanswered counts as shown, without changing its spacing.
    func endWait() {
        if let id = current?.cardID { try? reviews?.recordShown(cardID: id) }
        current = nil
    }
}
