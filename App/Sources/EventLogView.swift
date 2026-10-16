import SwiftUI
import MeanwhileIPC

/// Debug window for task 0.2: every hook event as it arrives, with its full JSON.
struct EventLogView: View {
    let log: EventLog
    @State private var selection: DebugEvent.ID?

    var body: some View {
        HSplitView {
            List(log.events.reversed(), selection: $selection) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.receivedAt, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(event.agent)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .background(.quaternary, in: Capsule())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.event).font(.body.weight(.medium))
                        if !event.summary.isEmpty {
                            Text(event.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .frame(minWidth: 360)

            ScrollView {
                Text(selectedJSON)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(minWidth: 420)
        }
        .frame(minWidth: 820, minHeight: 480)
        .toolbar {
            ToolbarItemGroup {
                if let error = log.serverError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Text("\(log.events.count) events").foregroundStyle(.secondary)
                }
                Button("Show Recording") {
                    NSWorkspace.shared.activateFileViewerSelecting([MeanwhilePaths.debugRecording])
                }
                Button("Clear") { log.clear() }
            }
        }
    }

    private var selectedJSON: String {
        log.events.first { $0.id == selection }?.prettyJSON ?? "Select an event to see its JSON."
    }
}
