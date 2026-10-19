import AppKit
import SwiftUI
import MeanwhileCore
import MeanwhileIPC

/// Starts the background notch process: a plain AppKit app, since a SwiftUI `@main App`
/// can't share the entry point with the CLI subcommands.
@MainActor
enum MenuBarApp {
    static func run() -> Never {
        let app = NSApplication.shared
        // No Dock icon or app menu, like LSUIElement in the old Info.plist.
        app.setActivationPolicy(.accessory)
        app.mainMenu = editMenu()
        // NSApplication.delegate is weak, and the status item disappears when released,
        // so both are held here for the life of the process.
        let delegate = AppDelegate()
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

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init()
        item.button?.image = NSImage(systemSymbolName: "questionmark.bubble", accessibilityDescription: "Meanwhile")
        let menu = NSMenu()
        let version = NSMenuItem(title: "Meanwhile \(Meanwhile.version)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        add("Show Event Log", #selector(showEventLog), key: "l", to: menu)
        menu.addItem(.separator())
        // Task 0.4 spike controls. The delay gives you time to click back into the terminal.
        add("Ask Test Question in 3 s", #selector(askSoon), to: menu)
        add("Compact Notch", #selector(compactNotch), to: menu)
        add("Hide Notch", #selector(hideNotch), to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Meanwhile", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    private func add(_ title: String, _ action: Selector, key: String = "", to menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
    }

    @objc private func showEventLog() { delegate.showEventLog() }
    @objc private func askSoon() { delegate.askSoon() }
    @objc private func compactNotch() { delegate.notch.compact() }
    @objc private func hideNotch() { delegate.notch.hide() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: EventStore?
    let log: EventLog
    let notch = NotchController()
    private var eventLogWindow: NSWindow?
    private var pruneTimer: Timer?

    override init() {
        var error: String?
        do {
            store = try EventStore()
        } catch let failure {
            store = nil
            error = "Could not open \(MeanwhilePaths.eventStore.path): \(failure)"
        }
        log = EventLog(store: store, storeError: error)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Events hold prompts and code; keep only the retention window (30 days).
        _ = try? store?.prune()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [store] _ in
            _ = try? store?.prune()
        }

        // Spike wiring: a prompt opens a question; when the agent stops or needs you, step aside.
        // Not on `PermissionRequest`: Claude Code sends it even when auto mode approves the
        // call. The `Notification` that follows a real prompt to the user is the signal.
        log.onAgentEvent = { [notch] event, payload in
            switch event {
            case "UserPromptSubmit":
                notch.ask()
            case "Notification":
                let type = payload["notification_type"] as? String
                if type == "permission_prompt" || type == "idle_prompt" { notch.hide() }
            case "Stop", "StopFailure", "SessionEnd":
                notch.hide()
            default:
                break
            }
        }
        // Until the notch UI exists, the Event Log is the only window, and the menu bar
        // icon can be hidden behind the notch. Open the log at launch.
        showEventLog()
    }

    func applicationWillTerminate(_ notification: Notification) {
        notch.shutdown()
        log.stop()
    }

    func askSoon() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            notch.ask()
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
