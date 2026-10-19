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

    /// A random card from the decks that apply to the repo at `cwd`. The scheduler (task 1.5)
    /// replaces the random pick.
    func randomQuestion(forDirectory cwd: String) -> SpikeQuestion? {
        let packs = library.packs(forDirectory: cwd, disabled: disabled)
        guard let pack = packs.filter({ !$0.cards.isEmpty }).randomElement(),
              let card = pack.cards.randomElement() else { return nil }
        return SpikeQuestion(card: card, deck: pack.title)
    }
}
