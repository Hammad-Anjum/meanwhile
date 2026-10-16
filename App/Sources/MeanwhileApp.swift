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
            Button("Quit Meanwhile") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let log = EventLog()
    private var eventLogWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Until the notch UI exists, the Event Log is the only window, and the menu bar
        // icon can be hidden behind the notch. Open the log at launch.
        showEventLog()
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
