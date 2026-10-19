import MeanwhileCore
import SwiftUI

/// Colors from mockup/index.html.
enum NotchColor {
    static let accent = Color(red: 0.91, green: 0.69, blue: 0.29)    // #E8B04B
    static let right = Color(red: 0.37, green: 0.70, blue: 1.0)      // #5FB3FF
    static let wrong = Color(red: 1.0, green: 0.54, blue: 0.36)      // #FF8A5C
    static let text = Color(red: 0.93, green: 0.93, blue: 0.94)      // #ECEDEF
    static let muted = Color(red: 0.64, green: 0.65, blue: 0.69)     // #A3A7B0

    /// A steady color per deck, so a deck is recognizable at a glance.
    static func deck(_ name: String) -> Color {
        let palette: [Color] = [right, accent, Color(red: 0.37, green: 0.82, blue: 0.71),
                                Color(red: 0.75, green: 0.55, blue: 1.0), wrong, Color(red: 0.98, green: 0.45, blue: 0.62)]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}

// MARK: - Expanded

struct NotchExpandedView: View {
    @ObservedObject var model: NotchModel
    weak var controller: NotchController?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusLine(model: model)
            content
            footer
        }
        .foregroundStyle(NotchColor.text)
        .frame(width: 440, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .question(let state):
            QuestionView(model: model, state: state, controller: controller)
        case .enough:
            EmptyNote(title: "That’s enough for this wait",
                      detail: "You hit your limit of \(model.limit) questions. Keep an eye on the agent now.")
        case .recap:
            RecapView(model: model)
        case .optIn(let name, _):
            OptInView(name: name, controller: controller)
        case .nothing:
            EmptyNote(title: model.status == .done ? "Done" : "Getting a question ready",
                      detail: model.status == .done ? "No questions this time." : "No card fits your decks yet.")
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            Text(hint).font(.caption2).foregroundStyle(NotchColor.muted)
            Spacer()
            if case .question(let state) = model.content {
                // Nothing moves on by itself: after answering, the user reads, then picks Next.
                Button(state.answer == nil ? "Skip" : model.status == .done ? "See recap" : "Next") {
                    controller?.skipOrNext()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(state.answer == nil ? NotchColor.muted : NotchColor.accent)
            }
        }
    }

    private var hint: String {
        if case .optIn = model.content { return "Click or press ⌃⌥1–3" }
        guard case .question(let state) = model.content else { return "" }
        if model.isAwaitingConfidence { return "⌃⌥1–3 how sure · ⌃⌥↩ next" }
        return state.answer == nil ? "Click or press ⌃⌥1–\(state.question.options.count)" : "⌃⌥↩ next"
    }
}

/// "● Claude Code · working · 1:23 · meanwhile"
struct StatusLine: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 6) {
            switch model.status {
            case .working:
                PulsingDot()
                Text("\(model.agentName) · working · ") + Text(timer: model.turnStarted) + repo
            case .needsInput:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(NotchColor.accent)
                Text("\(model.agentName) needs you") + repo
            case .done:
                Image(systemName: "checkmark").foregroundStyle(NotchColor.right)
                Text("\(model.agentName) · finished") + duration + repo
            case .idle:
                Text("No agent running")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(NotchColor.muted)
    }

    private var repo: Text { Text(model.repo.isEmpty ? "" : " · \(model.repo)") }

    private var duration: Text {
        guard let end = model.turnEnded else { return Text("") }
        return Text(" in " + Duration.seconds(end.timeIntervalSince(model.turnStarted)).minutesSeconds)
    }
}

struct QuestionView: View {
    @ObservedObject var model: NotchModel
    let state: NotchModel.QuestionState
    weak var controller: NotchController?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DeckChip(deck: state.question.deck, topic: state.question.topic)
                Spacer()
                ProgressDots(asked: model.asked, limit: model.limit)
            }
            if let why = state.question.why {
                Text(why).font(.caption2).foregroundStyle(NotchColor.muted).lineLimit(1)
            }
            if model.status == .done, state.answer == nil {
                Text("The agent finished. Finish this one, then you’ll see your recap.")
                    .font(.caption)
                    .foregroundStyle(NotchColor.accent)
            }
            Text(state.question.text)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            if state.question.options.count == 2 {
                HStack(spacing: 8) { options }
            } else {
                VStack(spacing: 6) { options }
            }

            if state.answer == nil {
                Button("I don’t know, show me") { controller?.answer(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(NotchColor.muted)
            } else {
                feedback
            }
        }
    }

    private var options: some View {
        ForEach(Array(state.question.options.enumerated()), id: \.offset) { index, option in
            OptionRow(index: index, label: option, look: look(index)) { controller?.answer(index) }
                .disabled(state.answer != nil)
        }
    }

    private func look(_ index: Int) -> OptionRow.Look {
        guard let answer = state.answer else { return .open }
        if index == state.question.correct { return .right }
        if index == answer.choice { return .wrong }
        return .dim
    }

    @ViewBuilder private var feedback: some View {
        if let answer = state.answer {
            VStack(alignment: .leading, spacing: 8) {
                Text(answer.correct ? "Right" : answer.choice == nil ? "Here’s the answer" : "Not quite")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(answer.correct ? NotchColor.right : answer.choice == nil ? NotchColor.text : NotchColor.wrong)
                if let explanation = state.question.explanation {
                    Text(explanation)
                        .font(.system(size: 12))
                        .foregroundStyle(NotchColor.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if answer.correct {
                    HStack(spacing: 6) {
                        ForEach(Array(Confidence.allCases.enumerated()), id: \.offset) { index, level in
                            ConfidenceButton(index: index, level: level, chosen: state.confidence) {
                                controller?.choose(level)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct OptionRow: View {
    enum Look { case open, right, wrong, dim }

    let index: Int
    let label: String
    let look: Look
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .frame(width: 18, height: 18)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                Text(label).font(.system(size: 13)).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                switch look {
                case .right: Image(systemName: "checkmark.circle.fill").foregroundStyle(NotchColor.right)
                case .wrong: Image(systemName: "xmark.circle.fill").foregroundStyle(NotchColor.wrong)
                case .open, .dim: EmptyView()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .opacity(look == .dim ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        switch look {
        case .right: NotchColor.right.opacity(0.18)
        case .wrong: NotchColor.wrong.opacity(0.18)
        case .open, .dim: .white.opacity(0.08)
        }
    }
}

struct ConfidenceButton: View {
    let index: Int
    let level: Confidence
    let chosen: Confidence?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(index + 1)  \(title)")
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(chosen == level ? NotchColor.accent.opacity(0.3) : .white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(chosen != nil)
    }

    private var title: String {
        switch level {
        case .guessed: "Guessed"
        case .fairlySure: "Fairly sure"
        case .knewIt: "Knew it"
        }
    }
}

struct DeckChip: View {
    let deck: String
    let topic: String?

    var body: some View {
        let color = NotchColor.deck(deck)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(topic.map { "\(deck) · \($0)" } ?? deck)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
    }
}

/// One dot per question in the wait: done, current, still to come.
struct ProgressDots: View {
    let asked: Int
    let limit: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(limit, asked), id: \.self) { index in
                Circle()
                    .fill(index < asked - 1 ? NotchColor.muted : index == asked - 1 ? NotchColor.accent : .white.opacity(0.15))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel("Question \(asked) of up to \(limit)")
    }
}

struct RecapView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("This wait").font(.caption).foregroundStyle(NotchColor.muted)
                (Text("\(model.right) of \(model.results.count)").font(.system(size: 22, weight: .bold))
                    + Text("  right").font(.system(size: 13)).foregroundColor(NotchColor.muted))
            }
            ForEach(model.results) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.correct ? "checkmark" : "xmark")
                        .foregroundStyle(item.correct ? NotchColor.right : NotchColor.wrong)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.question.text).font(.system(size: 12)).lineLimit(1)
                        Text(item.question.topic.map { "\(item.question.deck) · \($0)" } ?? item.question.deck)
                            .font(.caption2)
                            .foregroundStyle(NotchColor.deck(item.question.deck))
                    }
                    Spacer()
                    Text(item.comesBack).font(.caption).foregroundStyle(NotchColor.muted)
                }
            }
        }
    }
}

/// "Turn on codebase questions for meanwhile?" Yes / Not now / Never (task 2.2).
struct OptInView: View {
    let name: String
    weak var controller: NotchController?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckChip(deck: "Your codebase", topic: nil)
            (Text("Turn on codebase questions for ") + Text(name).bold() + Text("?"))
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(NotchModel.OptInChoice.allCases, id: \.rawValue) { choice in
                    Button { controller?.optIn(choice) } label: {
                        Text("\(choice.rawValue + 1)  \(title(choice))")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(choice == .yes ? NotchColor.accent.opacity(0.3) : .white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func title(_ choice: NotchModel.OptInChoice) -> String {
        switch choice {
        case .yes: "Yes"
        case .notNow: "Not now"
        case .never: "Never"
        }
    }
}

struct EmptyNote: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.caption).foregroundStyle(NotchColor.muted)
        }
    }
}

// MARK: - Compact

struct NotchCompactLeading: View {
    @ObservedObject var model: NotchModel
    weak var controller: NotchController?

    var body: some View {
        HStack(spacing: 6) {
            switch model.status {
            case .working:
                PulsingDot()
                Text(timer: model.turnStarted)
            case .needsInput:
                Image(systemName: "exclamationmark.circle.fill")
                Text("Needs you")
            case .done:
                Image(systemName: "checkmark").foregroundStyle(NotchColor.right)
                Text("Done")
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .foregroundStyle(model.status == .needsInput ? NotchColor.wrong : NotchColor.accent)
        .padding(.leading, 4)
        .contentShape(Rectangle())
        .onTapGesture { controller?.expandFromCompact() }
    }
}

struct NotchCompactTrailing: View {
    @ObservedObject var model: NotchModel
    weak var controller: NotchController?

    var body: some View {
        Group {
            switch model.status {
            case .working where model.remaining > 0:
                Label("\(model.remaining)", systemImage: "questionmark.bubble")
            case .done where !model.results.isEmpty:
                Text("\(model.right)/\(model.results.count)")
            default:
                EmptyView()
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .foregroundStyle(NotchColor.text)
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        .onTapGesture { controller?.expandFromCompact() }
    }
}

struct PulsingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(NotchColor.accent)
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

extension Text {
    /// A live m:ss counter from `start`.
    init(timer start: Date) {
        self.init(timerInterval: start...Date.distantFuture, countsDown: false)
    }
}

extension Duration {
    var minutesSeconds: String {
        let seconds = Int(components.seconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
