import Foundation
import GRDB

/// Definitions and references per file, a reference graph, and PageRank over it (task 2.11;
/// Aider's repo map). Feeds the selector's Centrality signal and the code map in evidence packs.
///
/// v1 extracts with per-language patterns rather than tree-sitter: the result only ranks
/// files and names neighbors, so approximate is enough, and it needs no bundled grammars.
public struct SymbolIndexer: Sendable {
    /// A name defined in more files than this is too common to link files by (init, body, run…).
    public var ambiguousAbove = 5
    /// Per file, so a generated file can't flood the graph.
    public var maxReferencesPerFile = 2_000

    public let library: LibraryStore

    public init(library: LibraryStore) {
        self.library = library
    }

    public struct Definition: Equatable, Sendable {
        public let name: String
        public let kind: String
        public let line: Int
    }

    /// Extracts symbols from new code blobs, then re-ranks the repo's files when anything was
    /// extracted or the file set changed (`filesChanged`, e.g. removals). Returns blobs processed.
    @discardableResult
    public func process(root: String, newBlobs: [String], filesChanged: Bool = true) throws -> Int {
        let blobs = try library.unsymbolizedCodeBlobs(Set(newBlobs), root: root)
        if !blobs.isEmpty {
            let contents = try DocIndexer.readBlobs(root: root, blobs)
            try library.writer.write { db in
                let def = try db.makeStatement(sql: "INSERT INTO symbolDef (sha, name, kind, line) VALUES (?, ?, ?, ?)")
                let ref = try db.makeStatement(sql: "INSERT OR IGNORE INTO symbolRef (sha, name) VALUES (?, ?)")
                for (sha, path) in blobs {
                    try db.execute(sql: "UPDATE blob SET symbolized = 1 WHERE sha = ?", arguments: [sha])
                    guard let text = contents[sha] else { continue }
                    let definitions = Self.definitions(in: text, path: path)
                    for definition in definitions {
                        try def.execute(arguments: [sha, definition.name, definition.kind, definition.line])
                    }
                    let defined = Set(definitions.map(\.name))
                    for name in Self.references(in: text).subtracting(defined).prefix(maxReferencesPerFile) {
                        try ref.execute(arguments: [sha, name])
                    }
                }
            }
        }
        if !blobs.isEmpty || filesChanged { try rank(root: root) }
        return blobs.count
    }

    // MARK: Graph and rank

    /// How much a shared name says two files are related (after Aider): a type name counts
    /// double, a descriptive name fully, a short lowercase one half; divided by √(files defining it).
    static func linkWeight(_ name: String, definedInFiles count: Int) -> Double {
        let base = name.first?.isUppercase == true ? 2.0 : name.count >= 10 ? 1.0 : 0.5
        return base / Double(count).squareRoot()
    }

    /// A link needs at least this much weight: a type reference, or several real names.
    public var minimumLinkWeight = 1.0

    /// file → files it uses, with how strongly (summed name weights). Weak links are dropped:
    /// short names like `events` or `run` otherwise tie unrelated files together.
    func graph(root: String) throws -> [String: [String: Double]] {
        try library.writer.read { db in
            let definitions = try Row.fetchAll(db, sql: """
                SELECT f.path, d.name FROM symbolDef d JOIN fileEntry f ON f.sha = d.sha JOIN repo r ON r.id = f.repoId
                WHERE r.root = ?
                """, arguments: [root])
            var definedIn: [String: Set<String>] = [:]
            for row in definitions { definedIn[row["name"], default: []].insert(row["path"]) }
            definedIn = definedIn.filter { $0.value.count <= ambiguousAbove }

            let references = try Row.fetchAll(db, sql: """
                SELECT f.path, s.name FROM symbolRef s JOIN fileEntry f ON f.sha = s.sha JOIN repo r ON r.id = f.repoId
                WHERE r.root = ?
                """, arguments: [root])
            var edges: [String: [String: Double]] = [:]
            for row in references {
                let from: String = row["path"], name: String = row["name"]
                guard let targets = definedIn[name] else { continue }
                let weight = Self.linkWeight(name, definedInFiles: targets.count)
                for target in targets where target != from { edges[from, default: [:]][target, default: 0] += weight }
            }
            return edges.mapValues { $0.filter { $0.value >= minimumLinkWeight } }.filter { !$0.value.isEmpty }
        }
    }

    /// PageRank over weighted links (damping 0.85); `focus` biases the random jumps toward those files.
    static func pageRank(_ edges: [String: [String: Double]], nodes: Set<String>, focus: Set<String> = [],
                         iterations: Int = 25, damping: Double = 0.85) -> [String: Double] {
        guard !nodes.isEmpty else { return [:] }
        let list = Array(nodes)
        let focused = focus.intersection(nodes)
        let jump: [String: Double] = focused.isEmpty
            ? Dictionary(uniqueKeysWithValues: list.map { ($0, 1 / Double(list.count)) })
            : Dictionary(uniqueKeysWithValues: list.map { ($0, focused.contains($0) ? 1 / Double(focused.count) : 0) })
        var rank = jump
        for _ in 0..<iterations {
            var next = Dictionary(uniqueKeysWithValues: list.map { ($0, (1 - damping) * jump[$0]!) })
            var dangling = 0.0
            for node in list {
                let targets = (edges[node] ?? [:]).filter { nodes.contains($0.key) }
                let total = targets.values.reduce(0, +)
                if total == 0 { dangling += rank[node]!; continue }
                for (target, weight) in targets { next[target]! += damping * rank[node]! * weight / total }
            }
            // Rank from files with no links follows the jump distribution.
            for node in list { next[node]! += damping * dangling * jump[node]! }
            rank = next
        }
        return rank
    }

    /// Global PageRank as a percentile per file, stored for the selector.
    func rank(root: String) throws {
        let repoID = try library.repoID(root: root)
        let codeFiles = try library.writer.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT f.path FROM fileEntry f JOIN blob b ON b.sha = f.sha WHERE f.repoId = ? AND b.kind = 'code'
                """, arguments: [repoID]))
        }
        let ranks = Self.pageRank(try graph(root: root), nodes: codeFiles)
        let ordered = ranks.sorted { $0.value < $1.value }
        try library.writer.write { db in
            try db.execute(sql: "DELETE FROM fileRank WHERE repoId = ?", arguments: [repoID])
            let insert = try db.makeStatement(sql: "INSERT INTO fileRank (repoId, path, percentile) VALUES (?, ?, ?)")
            for (index, entry) in ordered.enumerated() {
                let percentile = ordered.count > 1 ? Double(index) / Double(ordered.count - 1) : 0.5
                try insert.execute(arguments: [repoID, entry.key, percentile])
            }
        }
    }

    /// Files around `paths` in the graph, most relevant first, with their definitions:
    /// "Sources/A.swift: func load, struct Cache". At most `characters` long.
    public func map(near paths: [String], root: String, characters: Int = 6_000, maxFiles: Int = 12) throws -> String {
        let edges = try graph(root: root)
        let focus = Set(paths)
        var neighbors = Set<String>()
        for path in paths { neighbors.formUnion((edges[path] ?? [:]).keys) }
        for (from, targets) in edges where !Set(targets.keys).isDisjoint(with: focus) { neighbors.insert(from) }
        let nodes = neighbors.union(focus)
        guard !neighbors.subtracting(focus).isEmpty else { return "" }
        let ranks = Self.pageRank(edges, nodes: nodes, focus: focus)
        var text = ""
        for path in neighbors.subtracting(focus).sorted(by: { ranks[$0, default: 0] > ranks[$1, default: 0] }).prefix(maxFiles) {
            let names = try library.definitions(of: path, root: root, limit: 8).map { "\($0.kind) \($0.name)" }
            let line = "\(path): \(names.isEmpty ? "—" : names.joined(separator: ", "))\n"
            guard text.count + line.count <= characters else { break }
            text += line
        }
        return text
    }

    // MARK: Extraction

    private static let patterns: [String: [(kind: String, regex: String)]] = [
        "swift": [("func", #"\bfunc\s+([A-Za-z_]\w*)"#), ("type", #"\b(?:class|struct|enum|protocol|actor)\s+([A-Z]\w*)"#),
                  ("extension", #"\bextension\s+([A-Z]\w*)"#)],
        "ts": [("func", #"\bfunction\s*\*?\s*([A-Za-z_$][\w$]*)"#), ("type", #"\b(?:class|interface|type|enum)\s+([A-Z][\w$]*)"#),
               ("const", #"\bexport\s+(?:const|let|var)\s+([A-Za-z_$][\w$]*)"#),
               ("const", #"^\s*(?:const|let)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\("#)],
        "py": [("def", #"^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)"#), ("class", #"^\s*class\s+([A-Za-z_]\w*)"#)],
        "go": [("func", #"^func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)"#), ("type", #"^type\s+([A-Za-z_]\w*)"#)],
        "rs": [("fn", #"\bfn\s+([A-Za-z_]\w*)"#), ("type", #"\b(?:struct|enum|trait|union)\s+([A-Z]\w*)"#)],
        "java": [("type", #"\b(?:class|interface|enum|record|object)\s+([A-Z]\w*)"#), ("fun", #"\bfun\s+([A-Za-z_]\w*)"#),
                 ("method", #"^\s*(?:public|private|protected|static|final|\s)+[\w<>\[\],\s]+\s+([a-z]\w*)\s*\("#)],
        "c": [("type", #"\b(?:struct|class|enum|union)\s+([A-Za-z_]\w*)\s*\{"#),
              ("func", #"^[A-Za-z_][\w\s\*&:<>]*?\b([A-Za-z_]\w*)\s*\([^;]*\)\s*\{"#)],
    ]

    private static func language(_ path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": "ts"
        case "py": "py"
        case "go": "go"
        case "rs": "rs"
        case "java", "kt", "kts", "scala": "java"
        case "c", "cc", "cpp", "h", "hpp", "m", "mm": "c"
        default: nil
        }
    }

    public static func definitions(in text: String, path: String) -> [Definition] {
        guard let language = language(path), let rules = patterns[language] else { return [] }
        var found: [Definition] = []
        var seen = Set<String>()
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for rule in rules {
                guard let regex = try? Regex(rule.regex), let match = try? regex.firstMatch(in: line),
                      match.output.count > 1, let name = match.output[1].substring.map(String.init),
                      name.count > 1, seen.insert(rule.kind + name).inserted else { continue }
                found.append(Definition(name: name, kind: rule.kind, line: number + 1))
            }
        }
        return found
    }

    /// Identifier-like words used in the file, minus language keywords.
    public static func references(in text: String) -> Set<String> {
        var names = Set<String>()
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber || character == "_" { current.append(character); continue }
            if current.count >= 3, let first = current.first, first.isLetter || first == "_", !keywords.contains(current) {
                names.insert(current)
            }
            current = ""
        }
        if current.count >= 3, !keywords.contains(current) { names.insert(current) }
        return names
    }

    private static let keywords: Set<String> = [
        "func", "class", "struct", "enum", "protocol", "extension", "return", "import", "public", "private", "static",
        "let", "var", "self", "Self", "true", "false", "nil", "null", "none", "None", "True", "False", "guard", "else",
        "for", "while", "switch", "case", "default", "break", "continue", "throw", "throws", "try", "catch", "async",
        "await", "function", "const", "export", "from", "interface", "type", "new", "this", "def", "lambda", "pass",
        "yield", "with", "not", "and", "elif", "fn", "impl", "pub", "mut", "use", "mod", "crate", "package", "void",
        "int", "string", "String", "bool", "Bool", "Int", "Double", "Float", "final", "override", "init", "deinit",
        "where", "some", "any", "inout", "internal", "fileprivate", "open", "typealias", "associatedtype", "actor",
    ]
}

extension LibraryStore {
    func unsymbolizedCodeBlobs(_ hashes: Set<String>, root: String) throws -> [(sha: String, path: String)] {
        guard !hashes.isEmpty else { return [] }
        return try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT b.sha, MIN(f.path) AS path FROM blob b
                JOIN fileEntry f ON f.sha = b.sha JOIN repo r ON r.id = f.repoId
                WHERE r.root = ? AND b.kind = 'code' AND b.skipReason IS NULL AND b.symbolized = 0
                GROUP BY b.sha
                """, arguments: [root])
                .compactMap { row in
                    let sha: String = row["sha"]
                    return hashes.contains(sha) ? (sha, row["path"]) : nil
                }
        }
    }

    public func definitions(of path: String, root: String, limit: Int = 8) throws -> [SymbolIndexer.Definition] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.name, d.kind, d.line FROM symbolDef d JOIN fileEntry f ON f.sha = d.sha
                JOIN repo r ON r.id = f.repoId WHERE r.root = ? AND f.path = ? ORDER BY d.line LIMIT ?
                """, arguments: [root, path, limit])
                .map { SymbolIndexer.Definition(name: $0["name"], kind: $0["kind"], line: $0["line"]) }
        }
    }

    /// The file's PageRank percentile in its repo (0 least central, 1 most); nil if unranked.
    public func centrality(of path: String, root: String) throws -> Double? {
        try writer.read { db in
            try Double.fetchOne(db, sql: """
                SELECT k.percentile FROM fileRank k JOIN repo r ON r.id = k.repoId WHERE r.root = ? AND k.path = ?
                """, arguments: [root, path])
        }
    }
}
