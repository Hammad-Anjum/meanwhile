import Foundation
import MeanwhileCore

/// The bundled decks and which ones the user turned off. Stored in user defaults until
/// the config file arrives (task 5.1).
@MainActor
final class Decks {
    private static let disabledKey = "disabledPacks"

    let library: PackLibrary
    /// Problems loading bundled packs; empty normally.
    let loadFailures: [String]

    private(set) var disabled: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabled).sorted(), forKey: Self.disabledKey) }
    }

    init() {
        (library, loadFailures) = PackLibrary.bundled()
        disabled = Set(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? [])
        for failure in loadFailures { FileHandle.standardError.write(Data("[decks] \(failure)\n".utf8)) }
    }

    func isEnabled(_ pack: Pack) -> Bool { !disabled.contains(pack.id) }

    func toggle(_ id: String) {
        if disabled.contains(id) { disabled.remove(id) } else { disabled.insert(id) }
    }

    /// The enabled decks that apply to the repo at `cwd`. `knownStacks` comes from the
    /// worker, which (unlike the app) can read repos under ~/Desktop.
    func packs(forDirectory cwd: String, knownStacks: Set<Stack>? = nil) -> [Pack] {
        library.packs(forDirectory: cwd, disabled: disabled, knownStacks: knownStacks)
    }
}
