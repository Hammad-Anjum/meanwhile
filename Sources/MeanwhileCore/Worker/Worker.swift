import Foundation
import GRDB
import MeanwhileIPC

/// `meanwhile work`: indexes repos and (from task 2.6) generates questions, outside the app.
///
/// Started by `meanwhile-hook`, so it has the agent terminal's file access. Every start
/// records its request first, then takes a lock; whoever holds the lock works through all
/// pending requests, so a request is never lost because another worker was busy.
public struct Worker: Sendable {
    public struct Request: Sendable, Equatable {
        public enum Reason: String, Sendable {
            case turnStart = "turn-start"
            case edit
            case turnEnd = "turn-end"
            case manual
        }

        public var directory: String
        public var reason: Reason
        public var agent: String?
        public var session: String?

        public init(directory: String, reason: Reason, agent: String? = nil, session: String? = nil) {
            self.directory = directory
            self.reason = reason
            self.agent = agent
            self.session = session
        }
    }

    public let library: LibraryStore
    public let lockPath: String
    /// The question model; nil means the configured provider, created when first needed.
    let model: QuestionModel?
    /// Where this turn's events are read from; nil means the app's event store.
    let events: EventStore?
    /// The hook sends its event to the app and starts the worker at the same moment, so wait
    /// briefly for the app to store the event before reading the turn.
    var eventSettle: TimeInterval

    public init(library: LibraryStore, lockPath: String = MeanwhilePaths.workerLock.path,
                model: QuestionModel? = nil, events: EventStore? = nil, eventSettle: TimeInterval = 1.5) {
        self.library = library
        self.lockPath = lockPath
        self.model = model
        self.events = events
        self.eventSettle = eventSettle
    }

    /// Queues `request` and, unless another worker holds the lock, works through the queue.
    /// Returns the number of requests this call processed (0 when another worker is running).
    @discardableResult
    public func submit(_ request: Request) throws -> Int {
        try library.enqueue(request)
        guard let lock = Self.tryLock(lockPath) else { return 0 }
        defer { Self.unlock(lock) }
        var processed = 0
        while let next = try library.dequeue() {
            try process(next)
            processed += 1
        }
        return processed
    }

    /// One request: index the repo if it's on, retire questions about changed code, prime a
    /// newly turned-on repo, then write questions about the turn if the budget allows.
    func process(_ request: Request) throws {
        if request.reason == .turnStart, let session = request.session {
            try GenerationBudget(library: library).turnStarted(session: session)
        }
        let root = StackDetector.repoRoot(for: request.directory)
        try library.noteRepo(root: root)
        // Worktrees of one repo share a project: its opt-in, card and question pool.
        if let checkouts = Self.checkouts(of: root) {
            // Every live worktree already seen, so none of them offers its own opt-in card.
            for checkout in checkouts.worktrees.union([root]) where try checkout == root || library.repo(root: checkout) != nil {
                try library.attach(root: checkout, toProject: checkouts.project)
            }
            try library.pruneCheckouts(ofProject: checkouts.project, liveWorktrees: checkouts.worktrees)
        }
        let repo = try library.noteRepo(root: root)
        // Repos turned on get the full index; others only what the opt-in card needs.
        if repo.state == .on, let indexed = try? RepoIndexer(library: library).index(root: root) {
            if !indexed.skippedUnchanged {
                try DocIndexer(library: library).process(root: root, newBlobs: indexed.newBlobs)
                try SymbolIndexer(library: library).process(
                    root: root, newBlobs: indexed.newBlobs, filesChanged: indexed.added + indexed.changed + indexed.removed > 0)
                try HistoryIndexer(library: library).update(root: root)
                try library.markStaleQuestions(root: root)
            }
            try library.recordStacks(StackDetector.stacks(inRepo: root), root: root)
            try library.writer.write { db in
                try db.execute(sql: "UPDATE repo SET accessError = NULL WHERE root = ?", arguments: [root])
            }
            try primeIfNeeded(root: root)
            try generate(for: request, root: root)
            return
        }
        let listing = try? Shell.run("git", ["-C", root, "ls-files", "-z"], timeout: 30)
        if let listing, listing.succeeded {
            let count = listing.stdout.split(separator: 0).count
            try library.recordAccess(root: root, fileCount: count, error: nil)
            try library.recordStacks(StackDetector.stacks(inRepo: root), root: root)
        } else {
            let reason = listing.map { $0.timedOut ? "git timed out" : $0.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? "git could not start"
            try library.recordAccess(root: root, fileCount: nil, error: reason.isEmpty ? "not readable" : reason)
        }
    }

    // MARK: Generation (tasks 2.6, 2.9)

    /// Live questions on an edit, post-turn questions at the end of a turn: one call each per
    /// turn, 20 a day, and only when the evidence scores at least 2.
    func generate(for request: Request, root: String) throws {
        let kind: (pack: EvidencePack.Kind, budget: GenerationBudget.Kind)
        switch request.reason {
        case .edit: kind = (.live, .live)
        case .turnEnd: kind = (.postTurn, .postTurn)
        case .turnStart, .manual: return
        }
        guard let session = request.session else { return }
        let budget = GenerationBudget(library: library)
        guard try budget.allows(kind.budget, session: session) else { return }

        if eventSettle > 0 { Thread.sleep(forTimeInterval: eventSettle) }
        guard let store = events ?? (try? EventStore()) else { return }
        let turn = try store.events(inSession: session)
        guard let pack = try EvidenceBuilder(library: library).build(kind: kind.pack, root: root, session: session, events: turn),
              QuestionGenerator.style(forScore: pack.score) != nil else { return }

        let model = self.model ?? Providers.configured()
        let start = Date()
        let drafts: [DraftQuestion]
        do {
            drafts = try QuestionGenerator(model: model).questions(from: pack)
        } catch {
            try budget.record(kind.budget, provider: model.name, repo: root, session: session,
                              succeeded: false, duration: Date().timeIntervalSince(start))
            return
        }
        try budget.record(kind.budget, provider: model.name, repo: root, session: session,
                          succeeded: true, duration: Date().timeIntervalSince(start))
        try library.addToPool(drafts, from: pack, kind: kind.pack.rawValue)
    }

    /// Once per turned-on repo: a short repo card and orientation questions from its docs.
    func primeIfNeeded(root: String) throws {
        guard try !library.isPrimed(root: root) else { return }
        let budget = GenerationBudget(library: library)
        guard try budget.allows(.primer, session: nil), let pack = try Primer(library: library, model: model ?? Providers.configured()).pack(root: root)
        else { return }
        let model = self.model ?? Providers.configured()
        let start = Date()
        let output: Primer.Output
        do {
            output = try Primer(library: library, model: model).run(pack)
        } catch {
            try budget.record(.primer, provider: model.name, repo: root, session: nil,
                              succeeded: false, duration: Date().timeIntervalSince(start))
            return
        }
        try budget.record(.primer, provider: model.name, repo: root, session: nil,
                          succeeded: true, duration: Date().timeIntervalSince(start))
        try library.setRepoCard(Redactor.redact(output.card), root: root)
        try library.addToPool(output.questions, from: pack, kind: GenerationBudget.Kind.primer.rawValue)
    }

    // MARK: Worktrees

    /// The project (main worktree) of the checkout at `root` and all the repo's live
    /// worktrees, from git; nil outside a git repo. Paths come back in `root`'s own spelling
    /// where they match it, since git reports them with symlinks resolved.
    static func checkouts(of root: String) -> (project: String, worktrees: Set<String>)? {
        guard let list = try? Shell.run("git", ["-C", root, "worktree", "list", "--porcelain"], timeout: 10),
              list.succeeded else { return nil }
        let paths = list.text.split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
        // The first entry is the main worktree (for a bare repo, the repo folder).
        guard let main = paths.first else { return nil }
        let resolvedRoot = canonical(root)
        func spelled(_ path: String) -> String {
            let resolved = canonical(path)
            if resolved == resolvedRoot { return root }
            // Same symlinked prefix as root (e.g. /var vs /private/var): reuse root's spelling.
            let rootSuffixParts = resolvedRoot.split(separator: "/", omittingEmptySubsequences: false)
            let rootParts = root.split(separator: "/", omittingEmptySubsequences: false)
            let common = zip(rootSuffixParts.reversed(), rootParts.reversed()).prefix { $0 == $1 }.count
            let resolvedPrefix = rootSuffixParts.dropLast(common).joined(separator: "/")
            let rootPrefix = rootParts.dropLast(common).joined(separator: "/")
            if resolvedPrefix != rootPrefix, resolved.hasPrefix(resolvedPrefix + "/") {
                return rootPrefix + resolved.dropFirst(resolvedPrefix.count)
            }
            return path
        }
        return (spelled(main), Set(paths.map(spelled)))
    }

    /// The path with every symlink resolved, as git reports it. (Foundation's
    /// `resolvingSymlinksInPath` maps /private/var back to /var, so it can't be used.)
    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Lock

    static func tryLock(_ path: String) -> Int32? {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func unlock(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

extension LibraryStore {
    func enqueue(_ request: Worker.Request) throws {
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO workRequest (directory, reason, agent, session, requestedAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [request.directory, request.reason.rawValue, request.agent, request.session, Date()])
        }
    }

    /// The oldest pending request, removed from the queue.
    func dequeue() throws -> Worker.Request? {
        try writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM workRequest ORDER BY id LIMIT 1") else { return nil }
            try db.execute(sql: "DELETE FROM workRequest WHERE id = ?", arguments: [row["id"] as Int64])
            return Worker.Request(directory: row["directory"],
                                  reason: Worker.Request.Reason(rawValue: row["reason"]) ?? .manual,
                                  agent: row["agent"], session: row["session"])
        }
    }

    public func pendingRequestCount() throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM workRequest") ?? 0 }
    }
}
