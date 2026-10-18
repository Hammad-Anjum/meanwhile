import AppKit
import DynamicNotchKit
import SwiftUI

// Task 0.4 spike: compact and expanded notch states, and the focus test
// (click an answer while the terminal keeps keyboard focus).

/// A hard-coded question until the question engine exists. Written by `codex exec`
/// in the 0.5 provider spike, from Sources/MeanwhileIPC/Spool.swift.
struct SpikeQuestion {
    let text: String
    let options: [String]
    let correct: Int

    static let sample = SpikeQuestion(
        text: "Why does Spool.drain rename events.ndjson before reading it?",
        options: [
            "So concurrent appends start a fresh file",
            "To sort events by timestamp",
            "To convert the file to valid JSON",
            "To change the file permissions",
        ],
        correct: 0
    )
}

/// What the notch shows. Shared by the compact and expanded views.
@MainActor
final class NotchModel: ObservableObject {
    enum Phase: Equatable {
        case asking
        case answered(choice: Int, via: String)
    }

    @Published var question = SpikeQuestion.sample
    @Published var phase = Phase.asking
    @Published var turnStarted = Date()
    @Published var answeredCount = 0
    /// Result of the focus check after an answer, e.g. "iTerm2 kept focus".
    @Published var focusReport = ""
    @Published var focusKept = true
}

@MainActor
final class NotchController {
    let model = NotchModel()
    private var notch: DynamicNotch<NotchExpandedView, NotchCompactLeading, NotchCompactTrailing>?
    private var collapseTask: Task<Void, Never>?

    init() {
        Hotkeys.shared.onAnswer = { [weak self] index in self?.answer(index, via: "hotkey ⌃⌥\(index + 1)") }
    }

    /// Shows a fresh question, expanded. Called on `UserPromptSubmit` and from the menu.
    func ask() {
        collapseTask?.cancel()
        model.phase = .asking
        model.focusReport = ""
        model.turnStarted = Date()
        Hotkeys.shared.enable()
        Task {
            await notchView().expand(on: Self.screen)
            makeClickThroughFocusSafe()
        }
    }

    /// Shrinks to the compact state (timer and count). Called after feedback.
    func compact() {
        collapseTask?.cancel()
        Task { await notchView().compact(on: Self.screen) }
    }

    func hide() {
        collapseTask?.cancel()
        Hotkeys.shared.disable()
        Task { await notch?.hide() }
    }

    func answer(_ choice: Int, via source: String) {
        guard model.phase == .asking, model.question.options.indices.contains(choice) else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        model.phase = .answered(choice: choice, via: source)
        Hotkeys.shared.disable()
        model.answeredCount += 1

        // Check a moment later, after AppKit has finished handling the click.
        collapseTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            let panelIsKey = notch?.windowController?.window?.isKeyWindow ?? false
            let stillFront = NSWorkspace.shared.frontmostApplication
            model.focusKept = !panelIsKey && !NSApp.isActive && stillFront == frontmost
            let name = stillFront?.localizedName ?? "?"
            model.focusReport = model.focusKept
                ? "\(name) kept keyboard focus"
                : "Focus moved (panel key: \(panelIsKey), Meanwhile active: \(NSApp.isActive))"
            print("[notch spike] answer \(choice + 1) via \(source): \(model.focusReport)")

            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await notchView().compact(on: Self.screen)
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
            expanded: { NotchExpandedView(model: model, onAnswer: { [weak self] in self?.answer($0, via: "click") }) },
            compactLeading: { NotchCompactLeading(model: model) },
            compactTrailing: { NotchCompactTrailing(model: model) }
        )
        notch = made
        return made
    }

    /// The built-in display if there is one (it has the notch), else the main screen.
    private static var screen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

// MARK: - Views

struct NotchExpandedView: View {
    @ObservedObject var model: NotchModel
    let onAnswer: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Your codebase", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                TurnTimer(start: model.turnStarted).foregroundStyle(.secondary)
            }
            Text(model.question.text)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(model.question.options.enumerated()), id: \.offset) { index, option in
                Button { onAnswer(index) } label: {
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .frame(width: 18, height: 18)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        Text(option).font(.system(size: 13))
                        Spacer(minLength: 0)
                        if case .answered = model.phase, index == model.question.correct {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if case .answered(let choice, _) = model.phase, choice == index {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.phase != .asking)
            }

            footer
        }
        .foregroundStyle(.white)
        .frame(width: 400)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var footer: some View {
        switch model.phase {
        case .asking:
            Text("Click an answer, or press ⌃⌥1–4")
                .font(.caption).foregroundStyle(.secondary)
        case .answered(_, let source):
            HStack(spacing: 6) {
                Image(systemName: model.focusKept ? "keyboard" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.focusKept ? .green : .orange)
                Text(model.focusReport.isEmpty ? "Checking focus…" : "\(model.focusReport) · \(source)")
            }
            .font(.caption)
        }
    }
}

struct NotchCompactLeading: View {
    @ObservedObject var model: NotchModel
    var body: some View {
        TurnTimer(start: model.turnStarted).foregroundStyle(.white).padding(.leading, 4)
    }
}

struct NotchCompactTrailing: View {
    @ObservedObject var model: NotchModel
    var body: some View {
        Label("\(model.answeredCount)", systemImage: "checkmark.bubble")
            .labelStyle(.titleAndIcon)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.trailing, 4)
    }
}

/// Time since the agent turn started, as m:ss.
struct TurnTimer: View {
    let start: Date
    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.caption.monospacedDigit().weight(.semibold))
        }
    }
}
