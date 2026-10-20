import AppKit
import SwiftUI
import MeanwhileCore
import MeanwhileIPC

/// Starts the background notch process: a plain AppKit app, since a SwiftUI `@main App`
/// can't share the entry point with the CLI subcommands.
@MainActor
enum MenuBarApp {
    static func run(showLog: Bool = false, record: Bool = false) -> Never {
        let app = NSApplication.shared
        // No Dock icon or app menu, like LSUIElement in the old Info.plist.
        app.setActivationPolicy(.accessory)
        app.mainMenu = editMenu()
        // NSApplication.delegate is weak, and the status item disappears when released,
        // so both are held here for the life of the process.
        let delegate = AppDelegate()
        delegate.showLogAtLaunch = showLog
        delegate.log.recording = record
        let statusMenu = StatusMenu(delegate: delegate)
        app.delegate = delegate
        let signals = terminateOnSignals()
        withExtendedLifetime((delegate, statusMenu, signals)) { app.run() }
        exit(0)
    }

    /// Ctrl-C and `pkill` quit through `NSApp.terminate`, so `applicationWillTerminate`
    /// still stops the event server and removes the socket.
    private static func terminateOnSignals() -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            return source
        }
    }

    /// Hidden for an accessory app, but key equivalents still route through it,
    /// so copy and select-all work in the Event Log and ⌘W closes it.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let item = NSMenuItem()
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        return main
    }
}

/// The menu bar icon and its menu.
@MainActor
final class StatusMenu: NSObject {
    private let delegate: AppDelegate
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let pacingMenu: PacingMenu

    init(delegate: AppDelegate) {
        self.delegate = delegate
        pacingMenu = PacingMenu(apply: { [weak delegate] settings in delegate?.apply(settings) })
        super.init()
        item.button?.image = NSImage(systemSymbolName: "questionmark.bubble", accessibilityDescription: "Meanwhile")
        let menu = NSMenu()
        let version = NSMenuItem(title: "Meanwhile \(Meanwhile.version)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        add("Show Event Log", #selector(showEventLog), key: "l", to: menu)
        menu.addItem(.separator())
        let decks = NSMenuItem(title: "Decks", action: nil, keyEquivalent: "")
        decks.submenu = decksMenu()
        menu.addItem(decks)
        let pacing = NSMenuItem(title: "Pacing", action: nil, keyEquivalent: "")
        pacing.submenu = pacingMenu.menu
        menu.addItem(pacing)
        menu.addItem(.separator())
        // For trying the notch without an agent. The delay gives you time to click back into the terminal.
        add("Ask a Question in 3 s", #selector(askSoon), to: menu)
        add("Show Questions", #selector(showQuestions), to: menu)
        add("Hide Notch", #selector(hideNotch), to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Meanwhile", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    /// One checkable item per deck. Stack decks only show up for repos using their stack.
    private func decksMenu() -> NSMenu {
        let menu = NSMenu(title: "Decks")
        for pack in delegate.decks.library.packs {
            let title = pack.kind == .stack ? "\(pack.title) · follows repo" : pack.title
            let item = NSMenuItem(title: title, action: #selector(toggleDeck(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pack.id
            item.state = delegate.decks.isEnabled(pack) ? .on : .off
            item.toolTip = pack.description
            menu.addItem(item)
        }
        if delegate.decks.library.packs.isEmpty {
            menu.addItem(withTitle: "No decks loaded", action: nil, keyEquivalent: "")
        }
        return menu
    }

    @objc private func toggleDeck(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate.decks.toggle(id)
        sender.state = sender.state == .on ? .off : .on
    }

    private func add(_ title: String, _ action: Selector, key: String = "", to menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
    }

    @objc private func showEventLog() { delegate.showEventLog() }
    @objc private func askSoon() { delegate.askSoon() }
    @objc private func hideNotch() { delegate.notch.hide() }
    @objc private func showQuestions() { delegate.notch.showQuestions() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: EventStore?
    let log: EventLog
    let notch = NotchController()
    let decks = Decks()
    let quiz: Quiz
    var showLogAtLaunch = false
    private var eventLogWindow: NSWindow?
    private var pruneTimer: Timer?
    private var tickTimer: Timer?
    private var tracker = SessionTracker()

    override init() {
        var errors: [String] = []
        do {
            store = try EventStore()
        } catch {
            store = nil
            errors.append("Could not open \(MeanwhilePaths.eventStore.path): \(error)")
        }
        var reviews: ReviewStore?
        do {
            reviews = try ReviewStore()
        } catch {
            errors.append("Could not open \(MeanwhilePaths.reviewStore.path): \(error)")
        }
        var library: LibraryStore?
        do {
            library = try LibraryStore()
        } catch {
            errors.append("Could not open \(MeanwhilePaths.libraryStore.path): \(error)")
        }
        quiz = Quiz(decks: decks, reviews: reviews, library: library)
        log = EventLog(store: store, storeError: errors.isEmpty ? nil : errors.joined(separator: " · "))
        super.init()
        notch.nextQuestion = { [quiz] in quiz.next() }
        notch.pendingOptIn = { [quiz] in quiz.pendingOptIn() }
        notch.onOptIn = { [quiz] root, choice in quiz.answerOptIn(root: root, choice: choice) }
        notch.onRecord = { [quiz] question, answer in quiz.record(question, answer) }
        notch.onRevise = { [quiz] question, confidence in quiz.revise(question, confidence: confidence) }
        notch.onSkip = { [quiz] question in quiz.skipped(question) }
        notch.onReport = { [quiz] question in quiz.report(question) }
        notch.capReached = { [quiz] in quiz.capReached }
    }

    /// Settings changed from the menu: saved to the config file and applied now.
    func apply(_ settings: UserSettings) {
        do {
            try settings.save()
        } catch {
            FileHandle.standardError.write(Data("[settings] could not save \(UserSettings.defaultURL.path): \(error)\n".utf8))
        }
        quiz.settings = settings
        notch.update(settings)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Events hold prompts and code; keep only the retention window (30 days).
        _ = try? store?.prune()
        // The launchd log would grow forever; keep it to a few megabytes. Same timer.
        _ = try? LogRotation.rotateIfNeeded(at: MeanwhilePaths.log)
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [store] _ in
            _ = try? store?.prune()
            _ = try? LogRotation.rotateIfNeeded(at: MeanwhilePaths.log)
        }

        // The notch follows the session tracker: a question while the agent works,
        // out of the way when it needs you or is done.
        log.onEvents = { [weak self] events in
            guard let self else { return }
            self.handle(events.compactMap { self.tracker.apply($0) })
            // After the transitions, so a new turn's wait exists before its edits are noted.
            if let outcome = self.quiz.note(events) {
                self.notch.resolvePrediction(correct: outcome.correct, note: outcome.note)
            }
        }
        var ticks = 0
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                ticks += 1
                // Hooks spool when the socket refuses them (a burst); pick those up while running.
                if ticks % 5 == 0 { self.log.drainSpool() }
                self.handle(self.tracker.tick(now: Date()))
                self.notch.tick(now: Date())
            }
        }
        // The menu bar icon can be hidden behind the notch on a crowded menu bar;
        // `meanwhile run --show-log` is the way in then.
        if showLogAtLaunch { showEventLog() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        notch.shutdown()
        log.stop()
    }

    /// Only the focused session (the most recently active one) moves the notch, so a
    /// second agent finishing doesn't hide the question for the one you're waiting on.
    private func handle(_ transitions: [SessionTransition]) {
        let focus = tracker.focused?.session
        for transition in transitions {
            let line = "[session \(transition.session.prefix(8))] \(transition.from.rawValue) → \(transition.to.rawValue)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        for transition in transitions where focus == nil || transition.session == focus {
            let state = tracker.sessions[transition.session]
            switch (transition.from, transition.to) {
            case (.needsInput, .working):
                notch.resume()
            case (_, .working):
                let cwd = state?.cwd ?? FileManager.default.currentDirectoryPath
                quiz.startWait(session: transition.session, cwd: cwd, prompt: state?.lastPrompt)
                notch.startTurn(agent: state?.agent ?? .claude, repo: quiz.repoName(for: cwd),
                                since: state?.turnStartedAt ?? Date(), settings: quiz.settings)
            case (_, .needsInput):
                notch.needsInput()
            case (_, .done):
                // An unanswered question stays to be finished; recording happens on answer.
                notch.finish()
            case (_, .idle), (_, .ended):
                quiz.endWait()
                notch.hide()
            }
        }
    }

    func askSoon() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            quiz.startWait(session: nil, cwd: tracker.focused?.cwd ?? FileManager.default.currentDirectoryPath)
            notch.askOnce(quiz.next() ?? .sample)
        }
    }

    func showEventLog() {
        if eventLogWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: EventLogView(log: log)))
            window.title = "Meanwhile Event Log"
            window.setContentSize(NSSize(width: 960, height: 600))
            window.isReleasedWhenClosed = false
            // Show on whatever Space you're on, including next to a full-screen terminal or editor.
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            eventLogWindow = window
        }
        eventLogWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
