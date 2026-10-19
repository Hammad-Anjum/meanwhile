import AppKit
import DynamicNotchKit
import MeanwhileCore
import SwiftUI

/// One question as the notch shows it: a deck card, or the sample question.
struct QuizQuestion: Equatable {
    /// The deck card this came from; nil for the sample question.
    var cardID: String?
    var deck: String
    var topic: String?
    let text: String
    let options: [String]
    /// For a prediction, -1 until the agent's work answers it.
    var correct: Int
    var explanation: String?
    /// Set for prediction questions (task 2.10): no right answer until the agent acts.
    var prediction: Prediction.Kind?
    /// Why it was picked, one short grey line under the deck chip (task 2.8).
    var why: String?

    /// A pooled codebase question (task 2.6).
    init(pool question: PoolQuestion) {
        self.init(cardID: question.id, deck: "Your codebase", topic: question.topic, text: question.question,
                  options: question.options, correct: question.correct, explanation: question.explanation)
    }

    init(cardID: String? = nil, deck: String, topic: String? = nil, text: String, options: [String],
         correct: Int, explanation: String? = nil, prediction: Prediction.Kind? = nil) {
        self.cardID = cardID
        self.deck = deck
        self.topic = topic
        self.text = text
        self.options = options
        self.correct = correct
        self.explanation = explanation
        self.prediction = prediction
    }

    init(card: Card, deck: String, topic: String?) {
        self.init(cardID: card.id, deck: deck, topic: topic, text: card.question, options: card.choices,
                  correct: card.correctChoice, explanation: card.explanation)
    }

    /// Written by `codex exec` in the 0.5 provider spike, from Sources/MeanwhileIPC/Spool.swift.
    static let sample = QuizQuestion(
        deck: "Your codebase",
        text: "Why does Spool.drain rename events.ndjson before reading it?",
        options: [
            "So concurrent appends start a fresh file",
            "To sort events by timestamp",
            "To convert the file to valid JSON",
            "To change the file permissions",
        ],
        correct: 0,
        explanation: "A hook appending at the same moment then writes to a new events.ndjson instead of one being read."
    )
}

/// One answered question, for the recap.
struct RecapItem: Identifiable, Equatable {
    let id = UUID()
    let question: QuizQuestion
    let correct: Bool
    /// "tomorrow", "in 4 days". Updated if a confidence is picked after the answer.
    var comesBack: String
}

/// Everything the notch views draw. The controller changes it; the views only read it.
@MainActor
final class NotchModel: ObservableObject {
    enum AgentStatus: Equatable {
        case idle, working, needsInput, done
    }

    struct Answer: Equatable {
        /// The chosen option; nil for "I don't know, show me".
        let choice: Int?
        let correct: Bool
    }

    struct QuestionState: Equatable {
        var question: QuizQuestion
        var answer: Answer?
        var confidence: Confidence?
        /// A prediction's pick, waiting for the agent to answer it.
        var lockedChoice: Int?
    }

    enum Content: Equatable {
        case nothing
        case question(QuestionState)
        /// The wait's question limit is reached.
        case enough
        case recap
        /// "Turn on codebase questions for <name>?" (task 2.2). Not counted as a question.
        case optIn(name: String, root: String)
    }

    /// The confidence buttons, in button and hotkey order: most sure first.
    static let confidenceOrder: [Confidence] = [.knewIt, .fairlySure, .guessed]

    /// The three answers to the opt-in card, in button and hotkey order.
    enum OptInChoice: Int, CaseIterable {
        case yes, notNow, never
    }

    @Published var status = AgentStatus.idle
    @Published var agentName = "Claude Code"
    @Published var repo = ""
    @Published var turnStarted = Date()
    @Published var turnEnded: Date?
    @Published var content = Content.nothing
    @Published var asked = 0
    @Published var limit = 3
    @Published var results: [RecapItem] = []

    var right: Int { results.filter(\.correct).count }

    /// Questions still to come in this wait, counting an unanswered one on screen.
    var remaining: Int {
        var open = 0
        if case .question(let state) = content, state.answer == nil { open = 1 }
        return max(0, limit - asked) + open
    }

    var isAwaitingConfidence: Bool {
        if case .question(let state) = content, state.question.prediction == nil,
           state.answer?.correct == true, state.confidence == nil { return true }
        return false
    }
}

/// Runs the notch through an agent turn: questions while the agent works, an attention
/// state when it needs you, and a recap and score when it finishes (docs/architecture.md, "States").
@MainActor
final class NotchController {
    let model = NotchModel()

    /// The next question for this wait, or nil when there is none.
    var nextQuestion: (() -> QuizQuestion?)?
    /// A repo to offer codebase questions for before the next question, if any: (name, root).
    var pendingOptIn: (() -> (name: String, root: String)?)?
    /// The user's answer to the opt-in card.
    var onOptIn: ((String, NotchModel.OptInChoice) -> Void)?
    /// Records an answer (with confidence when it was right); returns when the card comes back.
    var onRecord: ((QuizQuestion, NotchModel.Answer) -> String)?
    /// Applies a confidence picked after the answer was saved; returns when the card comes back.
    var onRevise: ((QuizQuestion, Confidence) -> String)?
    /// The user skipped the question on screen.
    var onSkip: ((QuizQuestion) -> Void)?
    /// "Report wrong question" (task 2.10).
    var onReport: ((QuizQuestion) -> Void)?
    /// A prediction picked and waiting for the agent: (question, choice).
    private var pendingPrediction: (question: QuizQuestion, choice: Int)?

    private var notch: DynamicNotch<NotchExpandedView, NotchCompactLeading, NotchCompactTrailing>?
    private var transitionTask: Task<Void, Never>?
    /// The short pause after a confidence pick, and the recap's timers. Questions themselves
    /// never move on by a timer: only the user moves on.
    private var pendingTask: Task<Void, Never>?

    init() {
        Hotkeys.shared.onAnswer = { [weak self] index in self?.hotkey(index) }
        Hotkeys.shared.onNext = { [weak self] in self?.next() }
    }

    // MARK: Agent turn

    /// A new agent turn: reset the wait and show its first question.
    func startTurn(agent: AgentEvent.Agent, repo: String, since: Date, limit: Int) {
        pendingPrediction = nil
        model.status = .working
        model.agentName = agent == .codex ? "Codex" : agent == .cursor ? "Cursor" : "Claude Code"
        model.repo = repo
        model.turnStarted = since
        model.turnEnded = nil
        model.results = []
        model.asked = 0
        model.limit = limit
        model.content = .nothing
        advance()
    }

    /// The agent is waiting on the user: step back to the attention state. What was on
    /// screen is kept exactly as it was, to come back to.
    func needsInput() {
        model.status = .needsInput
        Hotkeys.shared.disable()
        pendingTask?.cancel()
        showCompact()
    }

    /// The agent carried on after needing the user: back to what was on screen.
    func resume() {
        model.status = .working
        switch model.content {
        case .question, .recap, .optIn:
            Hotkeys.shared.enable()
            showExpanded()
        case .enough:
            showCompact()
        case .nothing:
            advance()
        }
    }

    /// The turn ended. A question on screen stays until the user moves on (with a banner
    /// if it is unanswered); then the recap.
    func finish() {
        model.status = .done
        model.turnEnded = Date()
        switch model.content {
        case .question, .optIn:
            showExpanded()
        default:
            showRecapOrDone()
        }
    }

    func hide() {
        pendingTask?.cancel()
        transitionTask?.cancel()
        Hotkeys.shared.disable()
        model.status = .idle
        model.content = .nothing
        guard let notch else { return }
        transitionTask = Task { await notch.hide() }
    }

    func shutdown() {
        pendingTask?.cancel()
        transitionTask?.cancel()
        Hotkeys.shared.disable()
    }

    /// From the menu: a one-off question outside an agent turn.
    func askOnce(_ question: QuizQuestion) {
        pendingPrediction = nil
        model.status = .working
        model.agentName = "Meanwhile"
        model.repo = ""
        model.turnStarted = Date()
        model.turnEnded = nil
        model.results = []
        model.asked = 0
        model.limit = 1
        model.content = .nothing
        show(question)
    }

    // MARK: User actions

    /// Saves the answer at once (a right one as "fairly sure" until a confidence is picked)
    /// and stays on the feedback until the user moves on.
    func answer(_ choice: Int?) {
        guard case .question(var state) = model.content, state.answer == nil else { return }
        if state.question.prediction != nil {
            // A prediction: lock the pick in; the agent's work answers it later.
            guard state.lockedChoice == nil, let choice else { return }
            state.lockedChoice = choice
            model.content = .question(state)
            pendingPrediction = (state.question, choice)
            return
        }
        let answer = NotchModel.Answer(choice: choice, correct: choice == state.question.correct)
        state.answer = answer
        model.content = .question(state)
        let comesBack = onRecord?(state.question, answer) ?? "later"
        model.results.append(RecapItem(question: state.question, correct: answer.correct, comesBack: comesBack))
    }

    /// A confidence pick corrects the saved answer, then moves on: picking is the user acting.
    func choose(_ confidence: Confidence) {
        guard case .question(var state) = model.content, state.answer?.correct == true, state.confidence == nil else { return }
        state.confidence = confidence
        model.content = .question(state)
        let comesBack = onRevise?(state.question, confidence) ?? "later"
        if let index = model.results.lastIndex(where: { $0.question == state.question }) {
            model.results[index].comesBack = comesBack
        }
        schedule(after: 0.6) { [weak self] in self?.moveOn() }
    }

    /// Skip (before answering) or Next (after, or after locking in a prediction).
    func skipOrNext() {
        guard case .question(let state) = model.content else { return }
        if state.answer == nil, state.lockedChoice == nil { onSkip?(state.question) }
        moveOn()
    }

    /// ⌃⌥↩: Next once the question is answered. Skipping stays a deliberate click.
    private func next() {
        if case .question(let state) = model.content, state.answer != nil || state.lockedChoice != nil { skipOrNext() }
    }

    /// The agent's work answered a prediction. `correct` is the option it matches, or nil when
    /// it went another way; `note` says what happened. Shown if still on screen; the recap either way.
    func resolvePrediction(correct: Int?, note: String) {
        guard let pending = pendingPrediction else { return }
        pendingPrediction = nil
        var question = pending.question
        question.correct = correct ?? -1
        question.explanation = note
        let right = correct == pending.choice
        model.results.append(RecapItem(question: question, correct: right, comesBack: "prediction"))
        if case .question(var state) = model.content, state.question.prediction == question.prediction,
           state.lockedChoice == pending.choice, state.answer == nil {
            state.question = question
            state.answer = NotchModel.Answer(choice: pending.choice, correct: right)
            model.content = .question(state)
        }
    }

    /// "Report wrong question": retire it, then move on.
    func reportWrong() {
        guard case .question(let state) = model.content, state.question.prediction == nil else { return }
        onReport?(state.question)
        model.results.removeAll { $0.question == state.question }
        moveOn()
    }

    /// Click on the compact notch: open whatever there is to see.
    func expandFromCompact() {
        switch model.content {
        case .nothing:
            if model.status == .done, !model.results.isEmpty { model.content = .recap; showExpanded() }
        default:
            showExpanded()
        }
    }

    /// An answer to the opt-in card, then on to the next question.
    func optIn(_ choice: NotchModel.OptInChoice) {
        guard case .optIn(_, let root) = model.content else { return }
        onOptIn?(root, choice)
        advance()
    }

    private func hotkey(_ index: Int) {
        if case .optIn = model.content {
            if let choice = NotchModel.OptInChoice(rawValue: index) { optIn(choice) }
        } else if model.isAwaitingConfidence {
            if NotchModel.confidenceOrder.indices.contains(index) { choose(NotchModel.confidenceOrder[index]) }
        } else if case .question(let state) = model.content, state.answer == nil,
                  state.question.options.indices.contains(index) {
            answer(index)
        }
    }

    // MARK: Flow

    /// After a question: the next one, the recap if the agent is done, or compact.
    private func moveOn() {
        pendingTask?.cancel()
        if model.status == .done { showRecapOrDone() } else { advance() }
    }

    private func advance() {
        if let repo = pendingOptIn?() {
            model.content = .optIn(name: repo.name, root: repo.root)
            Hotkeys.shared.enable()
            showExpanded()
        } else if let question = nextQuestion?() {
            show(question)
        } else {
            model.content = model.asked > 0 ? .enough : .nothing
            Hotkeys.shared.disable()
            showCompact()
        }
    }

    private func show(_ question: QuizQuestion) {
        model.asked += 1
        model.content = .question(NotchModel.QuestionState(question: question))
        Hotkeys.shared.enable()
        showExpanded()
    }

    private func showRecapOrDone() {
        Hotkeys.shared.disable()
        if model.results.isEmpty {
            model.content = .nothing
            showCompact()
            schedule(after: 4) { [weak self] in self?.hide() }
        } else {
            model.content = .recap
            showExpanded()
            // Hovering keeps it open (DynamicNotchKit `keepVisible`); then the score, then idle.
            schedule(after: 10) { [weak self] in
                guard let self else { return }
                self.model.content = .nothing
                self.showCompact()
                self.schedule(after: 4) { [weak self] in self?.hide() }
            }
        }
    }

    private func schedule(after seconds: Double, _ action: @escaping @MainActor () -> Void) {
        pendingTask?.cancel()
        pendingTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    // MARK: Window

    private func showExpanded() {
        transitionTask?.cancel()
        guard let screen = Self.screen else { return }
        let notch = notchView()
        transitionTask = Task { [weak self] in
            await notch.expand(on: screen)
            guard !Task.isCancelled else { return }
            self?.makeClickThroughFocusSafe()
        }
    }

    private func showCompact() {
        transitionTask?.cancel()
        guard let screen = Self.screen else { return }
        let notch = notchView()
        transitionTask = Task { [weak self] in
            await notch.compact(on: screen)
            guard !Task.isCancelled else { return }
            self?.makeClickThroughFocusSafe()
        }
    }

    /// DynamicNotchKit's panel is non-activating but can become key, so by default a
    /// click on it takes keyboard focus from the terminal. With `becomesKeyOnlyIfNeeded`
    /// the panel only becomes key for views that need typing (text fields), never for buttons.
    private func makeClickThroughFocusSafe() {
        (notch?.windowController?.window as? NSPanel)?.becomesKeyOnlyIfNeeded = true
    }

    private func notchView() -> DynamicNotch<NotchExpandedView, NotchCompactLeading, NotchCompactTrailing> {
        if let notch { return notch }
        let model = self.model
        let made = DynamicNotch(
            hoverBehavior: [.keepVisible, .increaseShadow],
            style: .auto, // notch shape on notched screens, a floating pill elsewhere
            expanded: { NotchExpandedView(model: model, controller: self) },
            compactLeading: { NotchCompactLeading(model: model, controller: self) },
            compactTrailing: { NotchCompactTrailing(model: model, controller: self) }
        )
        notch = made
        return made
    }

    /// The built-in display if there is one (it has the notch), else the main screen.
    private static var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
