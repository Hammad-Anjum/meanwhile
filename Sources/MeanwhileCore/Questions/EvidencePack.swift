import Foundation

/// The small, scoped input a question is written from (docs/question-engine.md, rule 4;
/// task 2.5). Its size depends on the turn, never on the repo: about 6,000 tokens at most.
public struct EvidencePack: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// While the agent works, after the first edit.
        case live
        /// After the turn ends: has the agent's final message.
        case postTurn = "post-turn"
    }

    public struct Section: Sendable, Equatable {
        public let title: String
        public let text: String
    }

    /// Something a question may cite. Validation (task 2.7) checks quotes against these.
    public struct Source: Sendable, Equatable {
        public let path: String
        /// The blob the text came from, when it came from the index or disk; nil for hook-only text.
        public let blob: String?
        public let text: String
    }

    public let kind: Kind
    public let root: String
    public let session: String
    public let sections: [Section]
    public let sources: [Source]
    /// docs/question-engine.md "Context score": what kind of question the evidence supports.
    public let score: Int
    /// True when the repo couldn't be read and only hook content was used.
    public let hookOnly: Bool
    /// The files this turn edited, most-edited first.
    public let editedPaths: [String]

    /// The pack as the model sees it.
    public var text: String {
        sections.map { "## \($0.title)\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// About 4 characters per token for English and code.
    public var estimatedTokens: Int { text.count / 4 }
}

/// Builds evidence packs from a turn's events, the repo on disk and the index.
public struct EvidenceBuilder: Sendable {
    public struct Budget: Sendable {
        /// Characters, at about 4 per token: 6,000 tokens in all.
        public var total = 24_000
        public var editsAndCode = 12_000
        public var docsAndHistory = 6_000
        /// About 1,500 tokens of neighbors from the symbol graph.
        public var repoMap = 6_000
        public var linesAroundEdit = 20
        public var maxFiles = 4
        public init() {}
    }

    public var budget = Budget()
    public let library: LibraryStore

    public init(library: LibraryStore) {
        self.library = library
    }

    /// The pack for the turn in `events` (the session's events since its last prompt).
    public func build(kind: EvidencePack.Kind, root: String, session: String, events: [AgentEvent]) throws -> EvidencePack? {
        let turn = Self.currentTurn(events)
        let edits = turn.flatMap { event -> [FileEdit] in
            if case .edit(let edits) = event.kind { return edits }
            return []
        }
        guard !edits.isEmpty else { return nil }

        let readable = (try library.repo(root: root))?.accessError == nil && FileManager.default.isReadableFile(atPath: root)
        let editedPaths = Self.rankedPaths(edits, root: root)
        var sections: [EvidencePack.Section] = []
        var sources: [EvidencePack.Source] = []

        // The user's prompt: what this turn is about.
        if let prompt = turn.lazy.compactMap({ if case .turnStart(let p) = $0.kind { p } else { nil } }).first {
            sections.append(.init(title: "The user asked the agent", text: Redactor.redact(String(prompt.prefix(1_500)))))
        }

        // Edits, with the code around them when the file can be read.
        var editText = ""
        for path in editedPaths.prefix(budget.maxFiles) {
            let fileEdits = edits.filter { Self.relative($0.path, root) == path }
            var block = "### \(path)\n"
            if Redactor.isSecretFile(path) {
                block += "(secret file: contents not included)\n"
            } else {
                let hunk = Self.render(fileEdits)
                block += hunk
                sources.append(.init(path: path, blob: nil, text: hunk))
                if readable, let around = codeAround(fileEdits, path: path, root: root) {
                    block += "\nCurrent code around the change (lines \(around.lines.lowerBound)–\(around.lines.upperBound)):\n\(around.text)\n"
                    sources.append(.init(path: path, blob: try library.blob(of: path, root: root), text: around.text))
                }
            }
            let remaining = budget.editsAndCode - editText.count
            guard remaining > 200 else { break }
            editText += String(Redactor.redact(block).prefix(remaining)) + "\n"
        }
        sections.append(.init(title: "What the agent changed", text: editText))

        // The agent's own explanation: the strongest "why" evidence.
        let reason = turn.lazy.compactMap { event -> String? in
            if case .turnEnd(let message, _) = event.kind { return message }
            return nil
        }.last ?? nil
        if kind == .postTurn, let reason, !reason.isEmpty {
            sections.append(.init(title: "The agent's summary", text: Redactor.redact(String(reason.prefix(2_000)))))
        }

        // Docs and history, from the index.
        var docsText = ""
        var docHits = 0, commitHits = 0
        if readable {
            var seen = Set<String>()
            let prompt = sections.first { $0.title == "The user asked the agent" }?.text ?? ""
            let docs = try library.docChunks(mentioning: editedPaths, root: root, limit: 4)
                + (prompt.isEmpty ? [] : try library.searchDocs(prompt, root: root, limit: 2))
            for doc in docs where seen.insert(doc.sha + doc.trail).inserted {
                let block = "### \(doc.path) › \(doc.trail)\n\(doc.body)\n"
                guard docsText.count + block.count <= budget.docsAndHistory else { break }
                docsText += Redactor.redact(block)
                sources.append(.init(path: doc.path, blob: doc.sha, text: doc.body))
                docHits += 1
            }
            for path in editedPaths.prefix(2) {
                let subjects = try library.commitSubjects(touching: path, root: root)
                guard !subjects.isEmpty else { continue }
                let block = "### Recent commits on \(path)\n" + subjects.map { "- \($0)" }.joined(separator: "\n") + "\n"
                guard docsText.count + block.count <= budget.docsAndHistory else { break }
                docsText += Redactor.redact(block)
                commitHits += 1
            }
        }
        if !docsText.isEmpty { sections.append(.init(title: "Docs and history about these files", text: docsText)) }

        // The code around the edited files: their neighbors in the reference graph (task 2.11).
        if readable {
            let map = try SymbolIndexer(library: library).map(near: editedPaths, root: root, characters: budget.repoMap)
            if !map.isEmpty { sections.append(.init(title: "Code map near these files", text: map)) }
        }

        // Other files the agent read: callers and callees, likely.
        let reads = Set(turn.compactMap { event -> String? in
            if case .read(let path) = event.kind { return Self.relative(path, root) }
            return nil
        }).subtracting(editedPaths)
        if !reads.isEmpty {
            sections.append(.init(title: "Other files the agent read", text: reads.sorted().prefix(10).joined(separator: "\n")))
        }

        let score = Self.contextScore(hasEdit: true, hasReason: kind == .postTurn && !(reason ?? "").isEmpty,
                                      docHits: docHits, commitHits: commitHits, relatedReads: !reads.isEmpty)
        let pack = EvidencePack(kind: kind, root: root, session: session, sections: sections, sources: sources,
                                score: score, hookOnly: !readable, editedPaths: editedPaths)
        return pack.text.count <= budget.total ? pack : Self.trimmed(pack, to: budget.total)
    }

    /// docs/question-engine.md: edit hunk 2, the agent's stated reason 2, a doc on the touched
    /// path 1, a commit message on it 1, a related file the agent read 1.
    static func contextScore(hasEdit: Bool, hasReason: Bool, docHits: Int, commitHits: Int, relatedReads: Bool) -> Int {
        (hasEdit ? 2 : 0) + (hasReason ? 2 : 0) + (docHits > 0 ? 1 : 0) + (commitHits > 0 ? 1 : 0) + (relatedReads ? 1 : 0)
    }

    // MARK: Pieces

    /// Events since the session's most recent prompt.
    static func currentTurn(_ events: [AgentEvent]) -> [AgentEvent] {
        guard let start = events.lastIndex(where: { if case .turnStart = $0.kind { $0.subagent == nil } else { false } }) else {
            return events
        }
        return Array(events[start...])
    }

    /// Edited paths relative to the repo, most-changed first.
    static func rankedPaths(_ edits: [FileEdit], root: String) -> [String] {
        var weight: [String: Int] = [:]
        for edit in edits { weight[relative(edit.path, root), default: 0] += edit.added.count + edit.removed.count + 1 }
        return weight.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    static func relative(_ path: String, _ root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    static func render(_ edits: [FileEdit]) -> String {
        edits.map { edit in
            var lines = ["(\(edit.change.rawValue)\(edit.movedTo.map { " → \($0)" } ?? ""))"]
            lines += edit.removed.prefix(60).map { "- \($0)" }
            lines += edit.added.prefix(80).map { "+ \($0)" }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n") + "\n"
    }

    /// Lines around where the added text now sits in the file on disk.
    func codeAround(_ edits: [FileEdit], path: String, root: String) -> (text: String, lines: ClosedRange<Int>)? {
        guard let content = try? String(contentsOfFile: root + "/" + path, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard let anchor = edits.lazy.flatMap(\.added).first(where: { $0.trimmingCharacters(in: .whitespaces).count > 3 }),
              let index = lines.firstIndex(where: { $0.contains(anchor) }) else { return nil }
        let added = edits.reduce(0) { $0 + $1.added.count }
        let start = max(0, index - budget.linesAroundEdit)
        let end = min(lines.count - 1, index + added + budget.linesAroundEdit)
        let text = lines[start...end].enumerated()
            .map { "\(start + $0.offset + 1)  \($0.element)" }.joined(separator: "\n")
        return (String(text.prefix(6_000)), (start + 1)...(end + 1))
    }

    /// Cuts sections from the end until the pack fits.
    static func trimmed(_ pack: EvidencePack, to limit: Int) -> EvidencePack {
        var sections = pack.sections
        while sections.map({ $0.text.count + $0.title.count + 5 }).reduce(0, +) > limit, let last = sections.last {
            let excess = sections.map { $0.text.count + $0.title.count + 5 }.reduce(0, +) - limit
            if last.text.count > excess + 100 {
                sections[sections.count - 1] = .init(title: last.title, text: String(last.text.prefix(last.text.count - excess)))
            } else {
                sections.removeLast()
            }
        }
        return EvidencePack(kind: pack.kind, root: pack.root, session: pack.session, sections: sections,
                            sources: pack.sources, score: pack.score, hookOnly: pack.hookOnly, editedPaths: pack.editedPaths)
    }
}
