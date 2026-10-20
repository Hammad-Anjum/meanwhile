import Carbon.HIToolbox

/// Global ⌃⌥1–4 to answer (or pick a confidence), ⌃⌥↩ for Next and ⌃⌥H to hide, without the mouse or
/// moving focus. Carbon hot keys need no Accessibility permission, unlike a global key monitor.
/// Registered only while a question is open, so other apps keep these keys otherwise.
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()
    private static let nextID: UInt32 = 100
    private static let hideID: UInt32 = 101

    /// Called with the answer index (0–3).
    var onAnswer: ((Int) -> Void)?
    /// Called for ⌃⌥↩.
    var onNext: (() -> Void)?
    /// Called for ⌃⌥H.
    var onHide: (() -> Void)?
    private var refs: [EventHotKeyRef] = []

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = id.id
            MainActor.assumeIsolated {
                switch pressed {
                case Hotkeys.nextID: Hotkeys.shared.onNext?()
                case Hotkeys.hideID: Hotkeys.shared.onHide?()
                default: Hotkeys.shared.onAnswer?(Int(pressed))
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func enable() {
        guard refs.isEmpty else { return }
        let keys = [(kVK_ANSI_1, 0), (kVK_ANSI_2, 1), (kVK_ANSI_3, 2), (kVK_ANSI_4, 3), (kVK_Return, Int(Self.nextID)),
                    (kVK_ANSI_H, Int(Self.hideID))]
        for (key, number) in keys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4D57_4851), id: UInt32(number)) // "MWHQ"
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
