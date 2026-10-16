import SwiftUI
import MeanwhileCore

@main
struct MeanwhileApp: App {
    @State private var log = EventLog()

    var body: some Scene {
        MenuBarExtra("Meanwhile", systemImage: "questionmark.bubble") {
            MenuContent(eventCount: log.events.count)
        }

        Window("Event Log", id: "event-log") {
            EventLogView(log: log)
        }
    }
}

private struct MenuContent: View {
    let eventCount: Int
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Meanwhile \(Meanwhile.version)")
        Button("Show Event Log (\(eventCount))") {
            openWindow(id: "event-log")
            NSApp.activate()
        }
        .keyboardShortcut("l")
        Divider()
        Button("Quit Meanwhile") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
