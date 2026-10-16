import SwiftUI
import MeanwhileCore

@main
struct MeanwhileApp: App {
    var body: some Scene {
        MenuBarExtra("Meanwhile", systemImage: "questionmark.bubble") {
            Text("Meanwhile \(Meanwhile.version)")
            Divider()
            Button("Quit Meanwhile") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
