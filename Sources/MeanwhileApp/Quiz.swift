import Foundation
import MeanwhileCore

/// The questions for one agent wait: picks from deck cards and pooled codebase questions with
/// selection v2 (task 2.8), and records answers and what was shown.
@MainActor
final class Quiz {
    private let decks: Decks
    private let reviews: ReviewStore?
    /// What the worker knows about repos; the app can't read repos under ~/Desktop itself.
    private let library: LibraryStore?
    let selector = QuestionSelector()
    private var asked: [QuestionSelector.Candidate] = []
    private var cwd = FileManager.default.currentDirectoryPath
    private var session: String?
    /// Files the agent edited this wait, relative to the repo: what "Agent changed …" means.
    private var editedPaths: Set<String> = []
    /// The card on screen and not yet answered or skipped, and its row in the shown log.
    private var open: (id: String, shown: Int64?)?
    /// The opt-in card is offered at most once per wait.
    private var offeredOptIn = false

    var limitPerWait: Int { selector.limitPerWait }

    init(decks: Decks, reviews: ReviewStore?, library: LibraryStore?) {
        self.decks = decks
        self.reviews = reviews
        self.library = library
    }

    /// Starts a new wait (an agent turn) in the repo at `cwd`.
    func startWait(session: String?, cwd: String) {
        endWait()
        asked = []
        saved = [:]
        editedPaths = []
        offeredOptIn = false
        self.session = session
        self.cwd = cwd
    }

    /// Notes the files the agent edits, so codebase questions about them come first.
    func note(_ events: [AgentEvent]) {
        guard let root = repo?.root else { return }
        for event in events where event.session == session {
            guard case .edit(let edits) = event.kind else { continue }
            for edit in edits {
                let prefix = root.hasSuffix("/") ? root : root + "/"
                editedPaths.insert(edit.path.hasPrefix(prefix) ? String(edit.path.dropFirst(prefix.count)) : edit.path)
            }
        }
    }

    /// The repo for this wait, once the worker has recorded it.
    var repo: LibraryStore.Repo? { try? library?.repo(containing: cwd) }

    /// The repo to offer codebase questions for, before the next question (task 2.2).
    func pendingOptIn() -> (name: String, root: String)? {
        guard !offeredOptIn, let repo, repo.shouldAsk() else { return nil }
        offeredOptIn = true
        return (repo.name, repo.root)
    }

    func answerOptIn(root: String, choice: NotchModel.OptInChoice) {
        let state: LibraryStore.Repo.State = switch choice {
        case .yes: .on
        case .notNow: .later
        case .never: .never
        }
        try? library?.answerOptIn(state, root: root)
    }

    /// The next question for this wait, or nil when its limit is reached or nothing fits.
    func next() -> QuizQuestion? {
        let repo = self.repo
        var questions: [String: QuizQuestion] = [:]
        var candidates: [QuestionSelector.Candidate] = []

        let packs = decks.packs(forDirectory: cwd, knownStacks: repo?.stacks)
        for pack in packs {
            for card in pack.cards {
                let topic = pack.topics.first { $0.id == card.topic }?.title
                questions[card.id] = QuizQuestion(card: card, deck: pack.title, topic: topic)
                candidates.append(.init(id: card.id, deck: pack.id, deckTitle: pack.title))
            }
        }
        if let repo, repo.state == .on, let library, let pool = try? library.poolQuestions(root: repo.root) {
            let busiest = max(1, (try? library.maxCommits(root: repo.root)) ?? 1)
            for question in pool {
                questions[question.id] = QuizQuestion(pool: question)
                candidates.append(.init(id: question.id, deck: "codebase", deckTitle: "Your codebase",
                                        file: question.sourcePath,
                                        codeSignals: signals(question, root: repo.root, busiest: busiest)))
            }
        }

        var context = QuestionSelector.Context()
        context.reviews = (try? reviews?.reviews()) ?? [:]
        context.deckStats = (try? reviews?.deckStats(since: Date().addingTimeInterval(-30 * 86_400))) ?? [:]
        context.recentSkips = (try? reviews?.skips(since: Date().addingTimeInterval(-7 * 86_400))) ?? [:]
        context.recentAccuracy = try? reviews?.recentAccuracy()
        context.askedThisWait = asked
        context.agentTouchedCode = !editedPaths.isEmpty

        guard let pick = selector.next(from: candidates, context: context),
              var question = questions[pick.candidate.id] else { return nil }
        question.why = pick.why
        asked.append(pick.candidate)
        let shown = try? reviews?.logShown(cardID: pick.candidate.id, deck: pick.candidate.deck, session: session,
                                           why: pick.why, terms: pick.terms)
        open = (pick.candidate.id, shown)
        return question
    }

    /// Recency, churn and authorship for a pooled question (docs/phase2-plan.md §2).
    private func signals(_ question: PoolQuestion, root: String, busiest: Int) -> QuestionSelector.CodeSignals {
        let touched = !editedPaths.isDisjoint(with: Set(question.evidence.keys).union([question.sourcePath]))
        let ageDays = Date().timeIntervalSince(question.createdAt) / 86_400
        let history = try? library?.history(of: question.sourcePath, root: root)
        return .init(recency: touched ? 1 : pow(0.5, ageDays),
                     hotspot: Double(history?.commits ?? 0) / Double(busiest),
                     notMine: history?.notMine ?? 0.5)
    }

    /// Saved answers by card, so a confidence picked later corrects the same answer.
    private var saved: [String: ReviewStore.RecordedAnswer] = [:]

    /// Saves an answer the moment it is given and returns when the card comes back. A right
    /// answer is saved as "fairly sure" until the user picks a confidence; a wrong answer
    /// starts over at one day either way.
    func record(_ question: QuizQuestion, _ answer: NotchModel.Answer) -> String {
        guard let id = question.cardID else { return "later" }
        close(id, .answered)
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
        close(id, .skipped)
        try? reviews?.recordShown(cardID: id)
    }

    /// Ends the wait. A question left unanswered counts as shown, without changing its spacing.
    func endWait() {
        if let open {
            try? reviews?.recordShown(cardID: open.id)
            close(open.id, .unanswered)
        }
        open = nil
    }

    private func close(_ id: String, _ outcome: ReviewStore.Outcome) {
        guard let open, open.id == id else { return }
        if let row = open.shown { try? reviews?.finishShown(row, outcome: outcome) }
        self.open = nil
    }

    /// The repo's folder name, for the notch's status line: from the worker's record when
    /// it has one (the app itself may not be able to look under ~/Desktop).
    func repoName(for cwd: String) -> String {
        (try? library?.repo(containing: cwd))?.name ?? (StackDetector.repoRoot(for: cwd) as NSString).lastPathComponent
    }
}
