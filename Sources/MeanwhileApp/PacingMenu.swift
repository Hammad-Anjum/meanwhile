import AppKit
import MeanwhileCore

/// The menu bar's Pacing submenu: round size, time between rounds and the question cap, each
/// from presets or typed in. Rebuilt every time it opens, so `meanwhile config` changes show.
@MainActor
final class PacingMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "Pacing")
    private let apply: (UserSettings) -> Void

    private struct Preset {
        let title: String
        let value: String
    }

    private static let groups: [(key: String, title: String, presets: [Preset])] = [
        ("questions_per_round", "Questions per Round",
         [1, 2, 3, 5].map { Preset(title: "\($0)", value: "\($0)") }),
        ("round_interval", "Time Between Rounds",
         [1, 2, 5, 10].map { Preset(title: "\($0) min", value: "\($0)m") }),
        ("max_questions", "Question Limit",
         [5, 10, 20, 50].map { Preset(title: "\($0)", value: "\($0)") } + [Preset(title: "No Limit", value: "none")]),
        ("max_questions_per", "Limit Counts",
         [Preset(title: "Per Agent Turn", value: "turn"), Preset(title: "Per Day", value: "day")]),
    ]

    init(apply: @escaping (UserSettings) -> Void) {
        self.apply = apply
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = UserSettings.load()
        for group in Self.groups {
            let current = settings.value(of: group.key) ?? ""
            let submenu = NSMenu(title: group.title)
            var matched = false
            for preset in group.presets {
                let item = entry(preset.title, key: group.key, value: preset.value)
                if Self.same(preset.value, current, key: group.key) {
                    item.state = .on
                    matched = true
                }
                submenu.addItem(item)
            }
            if group.key != "max_questions_per" {
                submenu.addItem(.separator())
                let custom = entry(matched ? "Custom…" : "Custom: \(current)…", key: group.key, value: nil)
                custom.state = matched ? .off : .on
                submenu.addItem(custom)
            }
            let item = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Config File", action: #selector(openConfig), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    private func entry(_ title: String, key: String, value: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = [key, value ?? ""]
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        let key = pair[0]
        var settings = UserSettings.load()
        guard let text = pair[1].isEmpty ? askForValue(key, current: settings.value(of: key) ?? "") : pair[1] else { return }
        do {
            try settings.set(key, to: text)
            apply(settings)
        } catch {
            let alert = NSAlert()
            alert.messageText = "That value doesn’t work"
            alert.informativeText = "\(error)"
            NSApp.activate()
            alert.runModal()
        }
    }

    /// A small dialog with a text field; nil when cancelled.
    private func askForValue(_ key: String, current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = Self.groups.first { $0.key == key }?.title ?? key
        alert.informativeText = UserSettings.keys.first { $0.name == key }.map { "Enter \($0.help)." } ?? ""
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    @objc private func openConfig() {
        let url = UserSettings.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) { try? UserSettings.load().save(to: url) }
        // No app may be set for .toml; show it in Finder then.
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// Preset and current value mean the same setting ("2m" and "120s", "none" and "none").
    private static func same(_ preset: String, _ current: String, key: String) -> Bool {
        var a = UserSettings(), b = UserSettings()
        guard (try? a.set(key, to: preset)) != nil, (try? b.set(key, to: current)) != nil else { return false }
        return a.value(of: key) == b.value(of: key)
    }
}
