import Foundation
import Testing
@testable import MeanwhileCore

/// Task 1.4: the pack format, the bundled starter decks, and stack detection.

@Test func bundledPacksAllLoadAndValidate() {
    let (library, failures) = PackLibrary.bundled()
    #expect(failures.isEmpty, "\(failures)")
    let ids = Set(library.packs.map(\.id))
    #expect(ids == ["llm-fundamentals", "prompting-agents", "system-design", "swift-macos", "typescript-react", "python"])
    for pack in library.packs {
        #expect(pack.cards.count >= 20, "\(pack.id) has \(pack.cards.count) cards")
        for card in pack.cards {
            #expect(card.choices.indices.contains(card.correctChoice), "\(card.id)")
        }
    }
}

@Test func cardIDsAreUniqueAcrossPacks() {
    let ids = PackLibrary.bundled().library.packs.flatMap { $0.cards.map(\.id) }
    #expect(Set(ids).count == ids.count)
}

@Test func thisRepoGetsTheSwiftDeck() throws {
    // The test bundle lives under .build inside the repo; walk up to the repo root.
    let root = StackDetector.repoRoot(for: Bundle.module.bundlePath)
    #expect(StackDetector.stacks(inRepo: root).contains(.swift))
    let ids = PackLibrary.bundled().library.packs(forDirectory: root, disabled: []).map(\.id)
    #expect(ids.contains("swift-macos") && !ids.contains("python") && ids.contains("system-design"))
}

@Test func disabledPacksAreLeftOut() {
    let library = PackLibrary.bundled().library
    let ids = library.packs(disabled: ["system-design", "swift-macos"], stacks: [.swift]).map(\.id)
    #expect(!ids.contains("system-design") && !ids.contains("swift-macos") && ids.contains("llm-fundamentals"))
}

@Test func detectsStacksFromBuildFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stacks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let web = root.appendingPathComponent("web")
    let api = root.appendingPathComponent("api")
    let ignored = root.appendingPathComponent("node_modules/x")
    for directory in [web, api, ignored] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data(#"{"dependencies":{"react":"^19"},"devDependencies":{"typescript":"^5"}}"#.utf8)
        .write(to: web.appendingPathComponent("package.json"))
    try Data().write(to: api.appendingPathComponent("pyproject.toml"))
    try Data().write(to: ignored.appendingPathComponent("Cargo.toml"))

    #expect(StackDetector.stacks(inRepo: root.path) == [.javascript, .typescript, .react, .python])
}

@Test func problemsCatchBadCards() throws {
    let json = """
    {"format":1,"id":"t","title":"T","description":"d","kind":"generic","stacks":[],
     "topics":[{"id":"a","title":"A"}],
     "cards":[
       {"id":"t.a.1","topic":"a","type":"multipleChoice","question":"Q?","options":["1","2","3"],"answer":5,"explanation":"e"},
       {"id":"t.a.1","topic":"b","type":"trueFalse","question":"Q?","answer":2,"explanation":"e"}
     ]}
    """
    let pack = try JSONDecoder().decode(Pack.self, from: Data(json.utf8))
    let problems = pack.problems().joined(separator: "\n")
    #expect(problems.contains("needs 4 options"))
    #expect(problems.contains("answer out of range"))
    #expect(problems.contains("duplicate id"))
    #expect(problems.contains("unknown topic"))
    #expect(problems.contains("doesn't match type"))
}

@Test func trueFalseCardsShowTrueAndFalse() throws {
    let card = try JSONDecoder().decode(Card.self, from: Data(#"""
    {"id":"x.a.1","topic":"a","type":"trueFalse","question":"Q?","answer":false,"explanation":"e"}
    """#.utf8))
    #expect(card.choices == ["True", "False"] && card.correctChoice == 1)
}
