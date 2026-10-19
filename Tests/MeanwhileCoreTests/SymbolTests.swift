import Foundation
import Testing
@testable import MeanwhileCore

/// Task 2.11: symbols, the reference graph, PageRank and the code map.

@Test func definitionsPerLanguage() {
    func names(_ text: String, _ path: String) -> [String] {
        SymbolIndexer.definitions(in: text, path: path).map { "\($0.kind) \($0.name)" }
    }
    #expect(names("final class Cache {\n  func load() {}\n}\nextension Cache {}\nprotocol Store {}", "a.swift")
        == ["type Cache", "func load", "extension Cache", "type Store"])
    #expect(names("export function fetchUser() {}\nexport const API_URL = 'x'\ninterface User {}\nconst handler = async (req) => {}", "a.ts")
        == ["func fetchUser", "const API_URL", "type User", "const handler"])
    #expect(names("class Limiter:\n    def allow(self):\n        pass\nasync def main():\n    pass", "a.py")
        == ["class Limiter", "def allow", "def main"])
    #expect(names("func (s *Server) Start() error {\n}\ntype Server struct {}", "a.go") == ["func Start", "type Server"])
    #expect(names("pub fn parse(input: &str) {}\nstruct Token {}", "a.rs") == ["fn parse", "type Token"])
    #expect(names("anything", "README.md").isEmpty)
}

@Test func referencesSkipKeywords() {
    let refs = SymbolIndexer.references(in: "let cache = Cache.shared\nreturn cache.load(id)")
    #expect(!refs.contains("id"), "names under 3 characters are too short to link by")
    #expect(refs.isSuperset(of: ["cache", "Cache", "shared", "load"]))
    #expect(!refs.contains("let") && !refs.contains("return"))
}

@Test func pageRankFavorsTheHub() {
    // a, b and c all use hub; hub uses nothing.
    let edges: [String: [String: Double]] = ["a": ["hub": 2], "b": ["hub": 2], "c": ["hub": 2, "a": 1]]
    let rank = SymbolIndexer.pageRank(edges, nodes: ["a", "b", "c", "hub"])
    #expect(rank.max { $0.value < $1.value }?.key == "hub")
    #expect(abs(rank.values.reduce(0, +) - 1) < 0.001, "a distribution")
    // Focused on c, its neighbor a gains over b.
    let focused = SymbolIndexer.pageRank(edges, nodes: ["a", "b", "c", "hub"], focus: ["c"])
    #expect(focused["a"]! > focused["b"]!)
}

private func symbolRepo() throws -> (URL, LibraryStore) {
    let repo = try makeGitRepo([
        "Sources/Store.swift": "struct Cache {\n  func loadEntries() {}\n}\n",
        "Sources/App.swift": "func start() {\n  let cache = Cache()\n  cache.loadEntries()\n}\n",
        "Sources/UI.swift": "func render() { _ = Cache() }\n",
        "Sources/Util.swift": "func clamp() {}\n",
    ])
    let library = try LibraryStore(path: nil)
    let indexed = try RepoIndexer(library: library).index(root: repo.path)
    try SymbolIndexer(library: library).process(root: repo.path, newBlobs: indexed.newBlobs)
    return (repo, library)
}

@Test func theMostUsedFileIsTheMostCentral() throws {
    let (repo, library) = try symbolRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    #expect(try library.centrality(of: "Sources/Store.swift", root: repo.path) == 1)
    #expect(try library.centrality(of: "Sources/Util.swift", root: repo.path)! < 1)
    let edges = try SymbolIndexer(library: library).graph(root: repo.path)
    #expect(edges["Sources/App.swift"] == ["Sources/Store.swift": 3], "type Cache (2) + loadEntries (1)")
}

@Test func linkWeightsFavorTypesAndDescriptiveNames() {
    #expect(SymbolIndexer.linkWeight("Cache", definedInFiles: 1) == 2)
    #expect(SymbolIndexer.linkWeight("loadEntries", definedInFiles: 1) == 1)
    #expect(SymbolIndexer.linkWeight("events", definedInFiles: 1) == 0.5, "short lowercase names alone don't link")
    #expect(SymbolIndexer.linkWeight("Cache", definedInFiles: 4) == 1, "shared by 4 files: halved")
}

@Test func codeMapNamesNeighborsAndTheirDefinitions() throws {
    let (repo, library) = try symbolRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let map = try SymbolIndexer(library: library).map(near: ["Sources/App.swift"], root: repo.path)
    #expect(map == "Sources/Store.swift: type Cache, func loadEntries\n")
    // Store.swift's neighbors are the files that use it.
    let users = try SymbolIndexer(library: library).map(near: ["Sources/Store.swift"], root: repo.path)
    #expect(users.contains("Sources/App.swift") && users.contains("Sources/UI.swift") && !users.contains("Util"))
}

@Test func ambiguousNamesLinkNothing() throws {
    var files: [String: String] = [:]
    for index in 1...6 { files["Sources/T\(index).swift"] = "struct T\(index) { func setup() {} }\n" }
    files["Sources/Caller.swift"] = "func go() { setup() }\n"
    let repo = try makeGitRepo(files)
    defer { try? FileManager.default.removeItem(at: repo) }
    let library = try LibraryStore(path: nil)
    let indexed = try RepoIndexer(library: library).index(root: repo.path)
    try SymbolIndexer(library: library).process(root: repo.path, newBlobs: indexed.newBlobs)
    #expect(try SymbolIndexer(library: library).graph(root: repo.path)["Sources/Caller.swift"] == nil)
}

@Test func evidencePacksIncludeTheCodeMap() throws {
    let (repo, library) = try symbolRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let events = [
        AgentEvent(agent: .claude, session: "s", timestamp: Date(), cwd: repo.path, kind: .turnStart(prompt: "start the cache")),
        AgentEvent(agent: .claude, session: "s", timestamp: Date(), cwd: repo.path,
                   kind: .edit([FileEdit(path: repo.path + "/Sources/App.swift", change: .modified, added: ["  cache.loadEntries()"])])),
    ]
    let pack = try #require(try EvidenceBuilder(library: library).build(kind: .live, root: repo.path, session: "s", events: events))
    #expect(pack.sections.contains { $0.title == "Code map near these files" && $0.text.contains("type Cache") })
}
