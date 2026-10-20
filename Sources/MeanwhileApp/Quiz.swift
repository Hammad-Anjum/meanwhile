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
    /// The notch limits a round and the cap is checked here, so the selector itself never
    /// stops a wait.
    private(set) var selector: QuestionSelector = {
        var selector = QuestionSelector()
        selector.limitPerWait = .max
        return selector
    }()
    /// Pacing and the cap, from the config file; re-read at every wait.
    var settings = UserSettings.load()
    private var asked: [QuestionSelector.Candidate] = []
    private var cwd = FileManager.default.currentDirectoryPath
    private var session: String?
    /// Files the agent edited this wait, relative to the repo: what "Agent changed …" means.
    private var editedPaths: Set<String> = []
    /// The card on screen and not yet answered or skipped, and its row in the shown log.
    private var open: (id: String, shown: Int64?)?
    /// Kept through the feedback screen so a later report updates the same display row.
    private var shownRows: [String: Int64] = [:]
    /// The opt-in card is offered at most once per wait.
    private var offeredOptIn = false
    /// This turn's prompt, for prediction options.
    private var prompt = ""
    /// At most one prediction per wait, as its first question (task 2.10).
    private var offeredPrediction = false
    /// The prediction waiting for the agent: its kind, and for files the path behind each option.
    private var pendingPrediction: (kind: Prediction.Kind, paths: [String])?

    /// Questions this wait, not counting predictions: what a per-turn cap counts.
    private var askedThisTurn: Int { asked.filter { $0.id != "prediction" }.count }

    /// The cap is reached for this turn or today, whichever the settings count.
    var capReached: Bool {
        let today = (try? reviews?.shownCount(since: Calendar.current.startOfDay(for: Date()))) ?? 0
        return settings.capReached(thisTurn: askedThisTurn, today: today)
    }

    init(decks: Decks, reviews: ReviewStore?, library: LibraryStore?) {
        self.decks = decks
        self.reviews = reviews
        self.library = library
    }

    /// Starts a new wait (an agent turn) in the repo at `cwd`.
    func startWait(session: String?, cwd: String, prompt: String? = nil) {
        endWait()
        asked = []
        saved = [:]
        shownRows = [:]
        editedPaths = []
        offeredOptIn = false
        offeredPrediction = false
        pendingPrediction = nil
        self.prompt = prompt ?? ""
        self.session = session
        settings = UserSettings.load()
        self.cwd = cwd
    }

    /// Notes the files the agent edits, so codebase questions about them come first, and
    /// returns the answer to a waiting prediction once the agent's work gives it.
    func note(_ events: [AgentEvent]) -> (correct: Int?, note: String)? {
        guard let root = repo?.root else { return nil }
        let mine = events.filter { $0.session == session }
        for event in mine {
            guard case .edit(let edits) = event.kind else { continue }
            for edit in edits {
                let prefix = root.hasSuffix("/") ? root : root + "/"
                editedPaths.insert(edit.path.hasPrefix(prefix) ? String(edit.path.dropFirst(prefix.count)) : edit.path)
            }
        }
        guard let pending = pendingPrediction else { return nil }
        switch pending.kind {
        case .firstFile:
            guard let path = Prediction.firstEditedFile(mine, root: root) else { return nil }
            pendingPrediction = nil
            let index = pending.paths.firstIndex(of: path)
            return (index, index == nil ? "It went for \(path) first." : "It edited \(path) first.")
        case .testsPass:
            guard let passed = Prediction.firstTestRunPassed(mine) else { return nil }
            pendingPrediction = nil
            return (passed ? 0 : 1, passed ? "The first test run passed." : "The first test run failed.")
        }
    }

    /// A prediction about this turn, if the repo is on and there's something to predict:
    /// which file the agent changes first (when the prompt points at a few), else whether
    /// the tests pass first time (when the repo has tests).
    private func prediction() -> QuizQuestion? {
        guard !offeredPrediction, asked.isEmpty, !prompt.isEmpty, let repo, repo.state == .on,
              let paths = try? library?.filePaths(root: repo.root), !paths.isEmpty else { return nil }
        offeredPrediction = true
        if let files = Prediction.fileOptions(prompt: prompt, paths: paths) {
            pendingPrediction = (.firstFile, files)
            return QuizQuestion(deck: "Prediction", topic: "This turn", text: "Which file will the agent change first?",
                                options: files.map(Self.short), correct: -1, prediction: .firstFile)
        }
        if paths.contains(where: { $0.lowercased().contains("test") }) {
            pendingPrediction = (.testsPass, [])
            return QuizQuestion(deck: "Prediction", topic: "This turn", text: "Will the tests pass on the agent’s first run?",
                                options: ["Yes", "No"], correct: -1, prediction: .testsPass)
        }
        return nil
    }

    /// A path short enough for a notch option: the end of it, under 50 characters.
    private static func short(_ path: String) -> String {
        guard path.count > 48 else { return path }
        return "…" + path.suffix(47)
    }

    /// The repo for this wait, once the worker has recorded it.
    var repo: LibraryStore.Repo? { try? library?.repo(containing: cwd) }

    /// The repo to offer codebase questions for, before the next question (task 2.2).
    func pendingOptIn() -> (name: String, root: String)? {
        guard !offeredOptIn, let repo, repo.shouldAsk() else { return nil }
        offeredOptIn = true
        // Named for the project: the answer covers all its worktrees.
        return ((repo.project as NSString).lastPathComponent, repo.root)
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
        if let prediction = prediction() {
            // Takes a slot in the first round, but never counts toward the cap or enters
            // spaced repetition.
            asked.append(.init(id: "prediction", deck: "prediction", deckTitle: "Prediction"))
            return prediction
        }
        guard !capReached else { return nil }
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
        if let repo, repo.state == .on, let library, let pool = try? library.poolQuestions(visibleIn: repo.root) {
            let busiest = max(1, (try? library.maxCommits(root: repo.root)) ?? 1)
            for question in pool {
                questions[question.id] = QuizQuestion(pool: question)
                candidates.append(.init(id: question.id, deck: "codebase", deckTitle: "Your codebase",
                                        file: question.sourcePath,
                                        codeSignals: signals(question, root: repo.root, busiest: busiest),
                                        contextScore: question.score))
            }
        }

        var context = QuestionSelector.Context()
        context.reviews = (try? reviews?.reviews()) ?? [:]
        context.deckStats = (try? reviews?.deckStats(since: Date().addingTimeInterval(-30 * 86_400))) ?? [:]
        context.recentSkips = (try? reviews?.skips(since: Date().addingTimeInterval(-7 * 86_400))) ?? [:]
        context.recentAccuracy = try? reviews?.recentAccuracy()
        context.suppressed = (try? reviews?.suppressed()) ?? []
        context.askedThisWait = asked
        context.agentTouchedCode = !editedPaths.isEmpty

        guard let pick = selector.next(from: candidates, context: context),
              var question = questions[pick.candidate.id] else { return nil }
        question.why = pick.why
        asked.append(pick.candidate)
        let shown = try? reviews?.logShown(cardID: pick.candidate.id, deck: pick.candidate.deck, session: session,
                                           why: pick.why, terms: pick.terms)
        if let shown { shownRows[pick.candidate.id] = shown }
        open = (pick.candidate.id, shown)
        return question
    }

    /// Recency, churn and authorship for a pooled question (docs/phase2-plan.md §2).
    private func signals(_ question: PoolQuestion, root: String, busiest: Int) -> QuestionSelector.CodeSignals {
        let touched = !editedPaths.isDisjoint(with: Set(question.evidence.keys).union([question.sourcePath]))
        let ageDays = Date().timeIntervalSince(question.createdAt) / 86_400
        let history = try? library?.history(of: question.sourcePath, root: root)
        return .init(recency: touched ? 1 : pow(0.5, ageDays),
                     centrality: (try? library?.centrality(of: question.sourcePath, root: root)) ?? 0.5,
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

    /// "Report wrong question": a codebase question leaves the pool for good; a deck card is
    /// never shown again. Logged as reported either way (task 2.10).
    func report(_ question: QuizQuestion) {
        guard let id = question.cardID else { return }
        if id.hasPrefix("cb-") {
            try? library?.setStatus(.reported, question: id)
        } else {
            try? reviews?.suppress(cardID: id)
        }
        if let answer = saved.removeValue(forKey: id) { try? reviews?.discard(answer) }
        if let row = shownRows[id] { try? reviews?.reportShown(row) }
        if open?.id == id { open = nil }
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
