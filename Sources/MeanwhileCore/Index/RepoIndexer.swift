import Foundation
import GRDB

/// Keeps a repo's file map current without rescanning (task 2.3, docs/phase2-plan.md §1).
///
/// - Everything is keyed by git blob hash. `git ls-files -s` lists tracked files with their
///   hashes for free; only files modified in the working tree (and untracked docs) are hashed.
/// - If `HEAD` and `git status` are unchanged since last time, nothing runs.
/// - Content work (doc chunks, symbols) happens per new blob, so unchanged content and
///   branches switched back to are never processed twice.
public struct RepoIndexer: Sendable {
    public struct Limits: Sendable {
        /// GitHub code search skips files over 350 KiB.
        public var maxFileBytes = 350 * 1024
        public var maxFiles = 200_000
        public init() {}
    }

    public struct Result: Sendable, Equatable {
        public var skippedUnchanged = false
        public var files = 0
        public var added = 0
        public var changed = 0
        public var removed = 0
        /// Blobs seen for the first time, to process for docs and symbols.
        public var newBlobs: [String] = []
    }

    public let library: LibraryStore
    public var limits = Limits()

    public init(library: LibraryStore) {
        self.library = library
    }

    public func index(root: String) throws -> Result {
        let repoID = try library.repoID(root: root)
        let head = try? git(root, ["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = try git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]).stdout
        let statusHash = Self.fingerprint(status)
        if let previous = try library.indexState(repoID: repoID), previous.head == head, previous.status == statusHash {
            return Result(skippedUnchanged: true, files: try library.fileCount(repoID: repoID))
        }

        // Path → blob hash: tracked files from the index, then working-tree changes on top.
        var files = Self.parseLsFiles(try git(root, ["ls-files", "-s", "-z"]).stdout)
        let (modified, untracked, deleted) = Self.parseStatus(status)
        for path in deleted { files[path] = nil }
        let toHash = (modified + untracked.filter(FileKind.isDoc)).filter { files[$0] != nil || untracked.contains($0) }
        if !toHash.isEmpty {
            let hashes = try git(root, ["hash-object", "--stdin-paths"],
                                 input: toHash.joined(separator: "\n")).text.split(separator: "\n").map(String.init)
            for (path, hash) in zip(toHash, hashes) { files[path] = hash }
        }
        files = files.filter { !FileKind.isExcludedPath($0.key) }
        if files.count > limits.maxFiles {
            files = Dictionary(uniqueKeysWithValues: files.sorted { $0.key < $1.key }.prefix(limits.maxFiles).map { ($0.key, $0.value) })
        }

        // Sizes only for blobs not seen before; working-tree blobs may not be in git's store.
        let known = try library.knownBlobs(Set(files.values))
        let unknown = Set(files.values).subtracting(known)
        var sizes = try blobSizes(root: root, Array(unknown))
        for (path, hash) in files where unknown.contains(hash) && sizes[hash] == nil {
            sizes[hash] = (try? FileManager.default.attributesOfItem(atPath: root + "/" + path)[.size] as? Int) ?? 0
        }

        let previous = try library.fileEntries(repoID: repoID)
        var result = Result(files: files.count)
        for (path, hash) in files {
            if let old = previous[path] { if old != hash { result.changed += 1 } } else { result.added += 1 }
        }
        result.removed = previous.keys.filter { files[$0] == nil }.count
        result.newBlobs = unknown.sorted()

        // One path per new blob, for its kind (built once: searching per blob is quadratic).
        var pathOfBlob: [String: String] = [:]
        for (path, hash) in files where unknown.contains(hash) && pathOfBlob[hash] == nil { pathOfBlob[hash] = path }

        try library.writer.write { db in
            let insertBlob = try db.makeStatement(sql: "INSERT OR IGNORE INTO blob (sha, size, kind, skipReason) VALUES (?, ?, ?, ?)")
            for (hash, path) in pathOfBlob {
                let size = sizes[hash] ?? 0
                let skip = size > limits.maxFileBytes ? "too large" : FileKind.isBinary(path) ? "binary" : nil
                try insertBlob.execute(arguments: [hash, size, FileKind.kind(path).rawValue, skip])
            }
            // Apply only the difference, so a big repo with a small change writes little.
            let delete = try db.makeStatement(sql: "DELETE FROM fileEntry WHERE repoId = ? AND path = ?")
            for path in previous.keys where files[path] == nil {
                try delete.execute(arguments: [repoID, path])
            }
            let upsert = try db.makeStatement(sql: "INSERT OR REPLACE INTO fileEntry (repoId, path, sha) VALUES (?, ?, ?)")
            for (path, hash) in files where previous[path] != hash {
                try upsert.execute(arguments: [repoID, path, hash])
            }
            try db.execute(sql: "UPDATE repo SET head = ?, statusHash = ?, fileCount = ?, lastIndexedAt = ? WHERE id = ?",
                           arguments: [head, statusHash, files.count, Date(), repoID])
        }
        return result
    }

    // MARK: Git

    private func git(_ root: String, _ arguments: [String], input: String? = nil) throws -> Shell.Result {
        let result = try Shell.run("git", ["-C", root] + arguments, input: input.map { Data($0.utf8) }, timeout: 120)
        guard result.succeeded else { throw IndexError.git(arguments.first ?? "", result.stderr) }
        return result
    }

    /// `git cat-file --batch-check` sizes for blobs in git's object store.
    private func blobSizes(root: String, _ hashes: [String]) throws -> [String: Int] {
        guard !hashes.isEmpty else { return [:] }
        let output = try Shell.run("git", ["-C", root, "cat-file", "--batch-check=%(objectname) %(objectsize)"],
                                   input: Data(hashes.joined(separator: "\n").utf8), timeout: 120).text
        var sizes: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let size = Int(parts[1]) { sizes[String(parts[0])] = size }
        }
        return sizes
    }

    static func parseLsFiles(_ data: Data) -> [String: String] {
        var files: [String: String] = [:]
        for record in data.split(separator: 0) {
            // "<mode> <sha> <stage>\t<path>"
            guard let tab = record.firstIndex(of: 0x09) else { continue }
            let meta = String(decoding: record[record.startIndex..<tab], as: UTF8.self).split(separator: " ")
            let path = String(decoding: record[(tab + 1)...], as: UTF8.self)
            guard meta.count == 3, meta[0] != "160000" else { continue } // skip submodules
            files[path] = String(meta[1])
        }
        return files
    }

    /// `git status --porcelain=v1 -z`: modified, untracked and deleted paths.
    static func parseStatus(_ data: Data) -> (modified: [String], untracked: [String], deleted: [String]) {
        var modified: [String] = [], untracked: [String] = [], deleted: [String] = []
        var records = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }[...]
        while let record = records.popFirst() {
            guard record.count > 3 else { continue }
            let code = record.prefix(2)
            let path = String(record.dropFirst(3))
            if code == "??" { untracked.append(path); continue }
            if code.contains("R") || code.contains("C") { _ = records.popFirst() } // the old path follows
            if code.contains("D") { deleted.append(path) } else { modified.append(path) }
        }
        return (modified, untracked, deleted)
    }

    static func fingerprint(_ data: Data) -> String {
        // FNV-1a: only needs to tell "same status output" from "different".
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return "\(data.count)-\(String(hash, radix: 16))"
    }
}

public enum IndexError: Error, CustomStringConvertible {
    case git(String, String)
    public var description: String {
        switch self {
        case .git(let command, let stderr): "git \(command) failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// What kind of file a path is, and what the index skips (GitHub code search's rules plus
/// lockfiles, minified files and vendored or built folders).
public enum FileKind: String, Sendable {
    case doc, code, other

    static let docExtensions: Set<String> = ["md", "mdx", "markdown", "rst", "adoc", "txt"]
    static let docNames: Set<String> = ["CLAUDE.md", "AGENTS.md", "README", "CONTRIBUTING", "ARCHITECTURE"]
    static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "py", "rb", "java", "kt", "kts", "scala",
        "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte", "cs", "fs", "php", "ex", "exs", "erl", "clj",
        "lua", "dart", "sh", "zsh", "bash", "sql", "graphql", "proto", "tf", "zig", "nim", "ml", "hs",
    ]
    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "pdf", "zip", "gz", "tgz", "bz2", "xz", "7z", "jar",
        "dylib", "so", "a", "o", "dll", "exe", "bin", "wasm", "class", "pyc", "mp3", "mp4", "mov", "wav", "ttf",
        "otf", "woff", "woff2", "sqlite", "db", "psd", "sketch", "car",
    ]
    static let excludedNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Package.resolved", "Cargo.lock", "Gemfile.lock",
        "poetry.lock", "composer.lock", "go.sum", "Podfile.lock", "bun.lockb",
    ]
    static let excludedDirectories: Set<String> = [
        "node_modules", "vendor", "Pods", "Carthage", "dist", "build", "DerivedData", ".build", "target",
        "__pycache__", ".venv", "venv", ".yarn", "bower_components", ".next", "out", "coverage",
    ]

    public static func kind(_ path: String) -> FileKind {
        if isDoc(path) { return .doc }
        return codeExtensions.contains(fileExtension(path)) ? .code : .other
    }

    public static func isDoc(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return docExtensions.contains(fileExtension(path)) || docNames.contains(name)
            || path.contains(".cursor/rules/")
    }

    static func isBinary(_ path: String) -> Bool { binaryExtensions.contains(fileExtension(path)) }

    /// Paths the index never records.
    public static func isExcludedPath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if excludedNames.contains(name) || name.contains(".min.") || name.hasSuffix(".map") { return true }
        return path.split(separator: "/").dropLast().contains { excludedDirectories.contains(String($0)) }
    }

    private static func fileExtension(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }
}
