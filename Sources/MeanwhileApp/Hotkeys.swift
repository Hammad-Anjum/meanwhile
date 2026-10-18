import Carbon.HIToolbox

/// Global ⌃⌥1–4 to answer the notch question without the mouse or moving focus.
/// Carbon hot keys need no Accessibility permission, unlike a global key monitor.
/// Registered only while a question is open, so other apps keep these keys otherwise.
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()

    /// Called with the answer index (0–3).
    var onAnswer: ((Int) -> Void)?
    private var refs: [EventHotKeyRef] = []

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let index = Int(id.id)
            MainActor.assumeIsolated { Hotkeys.shared.onAnswer?(index) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func enable() {
        guard refs.isEmpty else { return }
        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4]
        for (index, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4D57_4851), id: UInt32(index)) // "MWHQ"
            let status = RegisterEventHotKey(
                UInt32(key), UInt32(controlKey | optionKey), id,
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    func disable() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }
}
