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
    let correct: Int
    var explanation: String?

    init(cardID: String? = nil, deck: String, topic: String? = nil, text: String, options: [String],
         correct: Int, explanation: String? = nil) {
        self.cardID = cardID
        self.deck = deck
        self.topic = topic
        self.text = text
        self.options = options
        self.correct = correct
        self.explanation = explanation
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
    /// "tomorrow", "in 4 days".
    let comesBack: String
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
    }

    enum Content: Equatable {
        case nothing
        case question(QuestionState)
        /// The wait's question limit is reached.
        case enough
        case recap
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
        if case .question(let state) = content, state.answer?.correct == true, state.confidence == nil { return true }
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
    /// Records an answer (with confidence when it was right); returns when the card comes back.
    var onRecord: ((QuizQuestion, NotchModel.Answer, Confidence?) -> String)?
    /// The user skipped the question on screen.
    var onSkip: ((QuizQuestion) -> Void)?

    private var notch: DynamicNotch<NotchExpandedView, NotchCompactLeading, NotchCompactTrailing>?
    private var transitionTask: Task<Void, Never>?
    /// Auto-advance or auto-hide timer; replaced by any user action.
    private var pendingTask: Task<Void, Never>?

    init() {
        Hotkeys.shared.onAnswer = { [weak self] index in self?.hotkey(index) }
    }

    // MARK: Agent turn

    /// A new agent turn: reset the wait and show its first question.
    func startTurn(agent: AgentEvent.Agent, repo: String, since: Date, limit: Int) {
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

    /// The agent is waiting on the user: step back to the attention state.
    func needsInput() {
        model.status = .needsInput
        Hotkeys.shared.disable()
        pendingTask?.cancel()
        showCompact()
    }

    /// The agent carried on after needing the user.
    func resume() {
        model.status = .working
        if case .question(let state) = model.content, state.answer == nil {
            showExpanded()
        } else {
            advance()
        }
    }

    /// The turn ended. An unanswered question stays (with a banner) so it can be finished.
    func finish() {
        model.status = .done
        model.turnEnded = Date()
        if case .question(let state) = model.content, state.answer == nil {
            showExpanded()
        } else if !model.isAwaitingConfidence {
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
        startTurn(agent: .claude, repo: "", since: Date(), limit: 1)
        if case .nothing = model.content { show(question) }
    }

    // MARK: User actions

    func answer(_ choice: Int?) {
        guard case .question(var state) = model.content, state.answer == nil else { return }
        let correct = choice == state.question.correct
        state.answer = NotchModel.Answer(choice: choice, correct: correct)
        model.content = .question(state)
        if correct {
            // Ask how sure; a quiet default if the user doesn't pick within a while.
            schedule(after: 12) { [weak self] in self?.choose(.fairlySure) }
        } else {
            Hotkeys.shared.disable()
            record(state, confidence: nil)
            schedule(after: 8) { [weak self] in self?.moveOn() }
        }
    }

    func choose(_ confidence: Confidence) {
        guard case .question(var state) = model.content, state.answer?.correct == true, state.confidence == nil else { return }
        state.confidence = confidence
        model.content = .question(state)
        Hotkeys.shared.disable()
        record(state, confidence: confidence)
        schedule(after: 0.6) { [weak self] in self?.moveOn() }
    }

    /// Skip (before answering) or Next (after).
    func skipOrNext() {
        guard case .question(let state) = model.content else { return }
        if state.answer == nil {
            onSkip?(state.question)
        } else if state.answer?.correct == true, state.confidence == nil {
            choose(.fairlySure)
            return
        }
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

    private func hotkey(_ index: Int) {
        if model.isAwaitingConfidence {
            if Confidence.allCases.indices.contains(index) { choose(Confidence.allCases[index]) }
        } else if case .question(let state) = model.content, state.answer == nil,
                  state.question.options.indices.contains(index) {
            answer(index)
        }
    }

    // MARK: Flow

    private func record(_ state: NotchModel.QuestionState, confidence: Confidence?) {
        guard let answer = state.answer else { return }
        let comesBack = onRecord?(state.question, answer, confidence) ?? "later"
        model.results.append(RecapItem(question: state.question, correct: answer.correct, comesBack: comesBack))
    }

    /// After a question: the next one, the recap if the agent is done, or compact.
    private func moveOn() {
        pendingTask?.cancel()
        if model.status == .done { showRecapOrDone() } else { advance() }
    }

    private func advance() {
        if let question = nextQuestion?() {
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
