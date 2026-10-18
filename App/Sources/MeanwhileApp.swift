import SwiftUI
import MeanwhileCore

@main
struct MeanwhileApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Meanwhile", systemImage: "questionmark.bubble") {
            Text("Meanwhile \(Meanwhile.version)")
            Button("Show Event Log") { appDelegate.showEventLog() }
                .keyboardShortcut("l")
            Divider()
            // Task 0.4 spike controls. The delay gives you time to click back into the terminal.
            Button("Ask Test Question in 3 s") { appDelegate.askSoon() }
            Button("Compact Notch") { appDelegate.notch.compact() }
            Button("Hide Notch") { appDelegate.notch.hide() }
            Divider()
            Button("Quit Meanwhile") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let log = EventLog()
    let notch = NotchController()
    private var eventLogWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Spike wiring: a prompt opens a question; when the agent stops or needs you, step aside.
        log.onAgentEvent = { [notch] event in
            switch event {
            case "UserPromptSubmit": notch.ask()
            case "PermissionRequest", "Notification", "Stop", "SessionEnd": notch.hide()
            default: break
            }
        }
        // Until the notch UI exists, the Event Log is the only window, and the menu bar
        // icon can be hidden behind the notch. Open the log at launch.
        showEventLog()
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
