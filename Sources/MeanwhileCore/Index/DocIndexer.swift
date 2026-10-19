import Foundation
import GRDB

/// Splits docs into heading chunks and indexes them for full-text search (task 2.4).
/// Chunks belong to a blob, so a doc that hasn't changed is never chunked again.
public struct DocIndexer: Sendable {
    /// Per repo; past this, new doc blobs are not chunked (docs/phase2-plan.md caps).
    public var maxChunksPerRepo = 50_000
    /// A chunk's body is capped; longer sections become several chunks.
    public var maxChunkCharacters = 2_000

    public let library: LibraryStore

    public init(library: LibraryStore) {
        self.library = library
    }

    /// Chunks the doc blobs among `newBlobs`. Returns the number of chunks added.
    @discardableResult
    public func process(root: String, newBlobs: [String]) throws -> Int {
        let docs = try library.unchunkedDocBlobs(Set(newBlobs), root: root)
        guard !docs.isEmpty else { return 0 }
        var budget = maxChunksPerRepo - (try library.docChunkCount(root: root))
        guard budget > 0 else { return 0 }

        let contents = try Self.readBlobs(root: root, docs)
        var added = 0
        try library.writer.write { db in
            let insert = try db.makeStatement(sql: "INSERT INTO docChunk (sha, ordinal, trail, body) VALUES (?, ?, ?, ?)")
            let index = try db.makeStatement(sql: "INSERT INTO docChunkFts (rowid, trail, body) VALUES (?, ?, ?)")
            let mention = try db.makeStatement(sql: "INSERT OR IGNORE INTO docMention (chunkId, token) VALUES (?, ?)")
            for (sha, path) in docs {
                // Mark the blob as chunked even if it yields nothing, so it isn't read again.
                try db.execute(sql: "UPDATE blob SET chunked = 1 WHERE sha = ?", arguments: [sha])
                guard budget > 0, let text = contents[sha], !Self.isUnindexable(text) else { continue }
                for (ordinal, chunk) in Self.chunks(text, title: path, maxCharacters: maxChunkCharacters).enumerated() {
                    guard budget > 0 else { break }
                    try insert.execute(arguments: [sha, ordinal, chunk.trail, chunk.body])
                    let id = db.lastInsertedRowID
                    try index.execute(arguments: [id, chunk.trail, chunk.body])
                    for token in Self.mentions(in: chunk.body) { try mention.execute(arguments: [id, token]) }
                    budget -= 1
                    added += 1
                }
            }
        }
        return added
    }

    // MARK: Chunking

    public struct Chunk: Equatable, Sendable {
        /// "Architecture › Storage › Events"
        public var trail: String
        public var body: String
    }

    /// Splits markdown at headings. Each chunk carries the trail of headings above it;
    /// text before the first heading is filed under `title`.
    public static func chunks(_ text: String, title: String, maxCharacters: Int = 2_000) -> [Chunk] {
        var chunks: [Chunk] = []
        var headings: [(level: Int, text: String)] = []
        var body: [String] = []
        var inFence = false

        func flush() {
            let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            body = []
            guard !joined.isEmpty else { return }
            let trail = headings.isEmpty ? title : headings.map(\.text).joined(separator: " › ")
            var rest = Substring(joined)
            while !rest.isEmpty {
                // Split long sections at a paragraph or line break near the cap.
                var piece = rest.prefix(maxCharacters)
                if rest.count > maxCharacters,
                   let cut = piece.range(of: "\n\n", options: .backwards) ?? piece.range(of: "\n", options: .backwards),
                   piece.distance(from: piece.startIndex, to: cut.lowerBound) > maxCharacters / 2 {
                    piece = piece[..<cut.lowerBound]
                }
                chunks.append(Chunk(trail: trail, body: String(piece).trimmingCharacters(in: .whitespacesAndNewlines)))
                rest = rest.dropFirst(piece.count).drop { $0.isNewline }
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, let level = headingLevel(line) {
                flush()
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                headings.removeAll { $0.level >= level }
                headings.append((level, text))
            } else {
                body.append(String(line))
            }
        }
        flush()
        return chunks.filter { !$0.body.isEmpty }
    }

    private static func headingLevel(_ line: Substring) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    /// File paths and code identifiers a chunk mentions: what links a doc to touched code.
    public static func mentions(in text: String) -> Set<String> {
        var tokens = Set<String>()
        // `Backticked` spans: identifiers, paths, commands.
        for match in text.matches(of: /`([^`\n]{2,80})`/) {
            let span = String(match.1).trimmingCharacters(in: .whitespaces)
            if !span.contains(" ") { tokens.insert(span) }
        }
        // Bare paths and file names: "Sources/App.swift", "README.md".
        for match in text.matches(of: /[A-Za-z0-9_\-\.\/]*[A-Za-z0-9_\-]+\.[A-Za-z]{1,10}\b/) {
            let token = String(match.0)
            if token.contains("/") || FileKind.kind(token) != .other { tokens.insert(token) }
        }
        // Add each path's file name too, so "App.swift" finds "Sources/App.swift".
        for token in tokens where token.contains("/") {
            tokens.insert((token as NSString).lastPathComponent)
        }
        return tokens
    }

    /// Git LFS pointers, and minified or generated text with very long lines.
    static func isUnindexable(_ text: String) -> Bool {
        if text.hasPrefix("version https://git-lfs") { return true }
        return text.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.utf8.count > 4096 }
    }

    // MARK: Reading blobs

    /// Contents by blob hash: from git's object store in one `cat-file --batch` call, or
    /// from the working tree for changes git hasn't stored.
    static func readBlobs(root: String, _ blobs: [(sha: String, path: String)]) throws -> [String: String] {
        let result = try Shell.run("git", ["-C", root, "cat-file", "--batch"],
                                   input: Data(blobs.map(\.sha).joined(separator: "\n").utf8), timeout: 120)
        var contents: [String: String] = [:]
        var data = result.stdout[...]
        while let newline = data.firstIndex(of: 0x0A) {
            let header = String(decoding: data[data.startIndex..<newline], as: UTF8.self).split(separator: " ")
            data = data[(newline + 1)...]
            guard header.count == 3, header[1] == "blob", let size = Int(header[2]), data.count >= size else { continue }
            contents[String(header[0])] = String(decoding: data.prefix(size), as: UTF8.self)
            data = data.dropFirst(size + 1)
        }
        for (sha, path) in blobs where contents[sha] == nil {
            contents[sha] = try? String(contentsOfFile: root + "/" + path, encoding: .utf8)
        }
        return contents
    }
}

extension LibraryStore {
    /// Doc blobs among `hashes` that are in this repo, not skipped and not chunked yet.
    func unchunkedDocBlobs(_ hashes: Set<String>, root: String) throws -> [(sha: String, path: String)] {
        guard !hashes.isEmpty else { return [] }
        return try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT b.sha, MIN(f.path) AS path FROM blob b
                JOIN fileEntry f ON f.sha = b.sha JOIN repo r ON r.id = f.repoId
                WHERE r.root = ? AND b.kind = 'doc' AND b.skipReason IS NULL AND b.chunked = 0
                GROUP BY b.sha
                """, arguments: [root])
            return rows.compactMap { row in
                let sha: String = row["sha"]
                return hashes.contains(sha) ? (sha, row["path"]) : nil
            }
        }
    }

    func docChunkCount(root: String) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM docChunk c WHERE c.sha IN
                  (SELECT f.sha FROM fileEntry f JOIN repo r ON r.id = f.repoId WHERE r.root = ?)
                """, arguments: [root]) ?? 0
        }
    }

    public struct DocHit: Sendable, Equatable {
        public let path: String
        public let trail: String
        public let body: String
        public let sha: String
    }

    /// Doc chunks in the repo's current docs that mention any of `paths` (or their file names).
    public func docChunks(mentioning paths: [String], root: String, limit: Int = 5) throws -> [DocHit] {
        let tokens = Set(paths.flatMap { [$0, ($0 as NSString).lastPathComponent] })
        guard !tokens.isEmpty else { return [] }
        return try writer.read { db in
            let marks = Array(repeating: "?", count: tokens.count).joined(separator: ",")
            return try Row.fetchAll(db, sql: """
                SELECT DISTINCT c.trail, c.body, c.sha, f.path FROM docMention m
                JOIN docChunk c ON c.id = m.chunkId
                JOIN fileEntry f ON f.sha = c.sha JOIN repo r ON r.id = f.repoId
                WHERE r.root = ? AND m.token IN (\(marks))
                ORDER BY c.sha, c.ordinal LIMIT ?
                """, arguments: StatementArguments([root] + Array(tokens) + [limit] as [any DatabaseValueConvertible]))
                .map { DocHit(path: $0["path"], trail: $0["trail"], body: $0["body"], sha: $0["sha"]) }
        }
    }

    /// Full-text search over the repo's current docs, best matches first.
    public func searchDocs(_ query: String, root: String, limit: Int = 5) throws -> [DocHit] {
        // Words as Strings: without the explicit conversion this picked Sequence.split and
        // quoted arrays of characters, so no search ever matched.
        let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0) }.filter { $0.count > 2 }.prefix(12)
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0)\"" }.joined(separator: " OR ")
        return try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.trail, c.body, c.sha, MIN(f.path) AS path, MIN(hit.rank) AS rank
                FROM (SELECT rowid, rank FROM docChunkFts WHERE docChunkFts MATCH ?) hit
                JOIN docChunk c ON c.id = hit.rowid
                JOIN fileEntry f ON f.sha = c.sha JOIN repo r ON r.id = f.repoId
                WHERE r.root = ?
                GROUP BY c.id ORDER BY rank LIMIT ?
                """, arguments: [match, root, limit])
                .map { DocHit(path: $0["path"], trail: $0["trail"], body: $0["body"], sha: $0["sha"]) }
        }
    }
}
