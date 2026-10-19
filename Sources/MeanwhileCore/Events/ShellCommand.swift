import Foundation

/// Reads a shell command well enough to see which files it views. Agents often read
/// files with `cat` or `sed -n` instead of a Read tool (seen in the 0.3 recordings).
/// A heuristic: unusual quoting or expansions just yield fewer paths.
enum ShellCommand {
    private static let viewers: Set<String> = ["cat", "head", "tail", "nl", "bat", "less", "more", "sed"]
    private static let shells: Set<String> = ["bash", "zsh", "sh"]

    /// Absolute paths of files the command views, in order, without duplicates.
    static func readPaths(in command: String, cwd: String) -> [String] {
        var directory = cwd
        var paths: [String] = []
        for words in segments(command) {
            var words = words[...]
            // Skip leading `VAR=value` assignments and `env`.
            while let first = words.first, first == "env" || isAssignment(first) { words.removeFirst() }
            guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            let arguments = Array(words.dropFirst())

            if program == "cd", let target = arguments.first {
                directory = resolve(target, in: directory)
            } else if shells.contains(program), let flag = arguments.firstIndex(where: { $0.hasPrefix("-") && $0.contains("c") }),
                      flag + 1 < arguments.count {
                paths += readPaths(in: arguments[flag + 1], cwd: directory)
            } else if viewers.contains(program) {
                paths += files(for: program, arguments).map { resolve($0, in: directory) }
            }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func files(for program: String, _ arguments: [String]) -> [String] {
        var operands: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext { skipNext = false; continue }
            if argument.hasPrefix("-") {
                // Options that take a separate value.
                if ["head", "tail"].contains(program), ["-n", "-c"].contains(argument) { skipNext = true }
                if program == "sed", ["-e", "-f"].contains(argument) { skipNext = true }
                continue
            }
            operands.append(argument)
        }
        // `sed -n '1,80p' file`: the first operand is the script. Only `sed -n` is a viewer.
        if program == "sed" {
            guard arguments.contains("-n") else { return [] }
            return Array(operands.dropFirst())
        }
        return operands
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func resolve(_ path: String, in directory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (directory as NSString).appendingPathComponent(expanded)
        return (absolute as NSString).standardizingPath
    }

    /// Splits on unquoted `&&`, `||`, `;`, `|` and newlines into simple commands, each a
    /// list of words with quotes removed. Redirections and their targets are dropped.
    static func segments(_ command: String) -> [[String]] {
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var dropNextWord = false

        func endWord() {
            if inWord {
                if dropNextWord { dropNextWord = false } else { words.append(word) }
            }
            word = ""
            inWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }

        var characters = command[...]
        while let character = characters.popFirst() {
            if let open = quote {
                if character == open { quote = nil }
                else if character == "\\", open == "\"", let next = characters.popFirst() { word.append(next) }
                else { word.append(character) }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                inWord = true
            case "\\":
                if let next = characters.popFirst(), next != "\n" { word.append(next); inWord = true }
            case " ", "\t":
                endWord()
            case "\n", ";", "&", "|":
                endSegment()
            case ">", "<":
                // `2>file`, `> file`, `<file`: drop the digit and the target.
                if inWord, word.allSatisfy(\.isNumber) { word = ""; inWord = false }
                endWord()
                if characters.first == ">" || characters.first == "&" { characters.removeFirst() }
                dropNextWord = true
            default:
                word.append(character)
                inWord = true
            }
        }
        endSegment()
        return segments
    }
}

/// Codex's `apply_patch` format: `*** Begin Patch`, then per file `*** Add File:`,
/// `*** Update File:` (optionally `*** Move to:`) or `*** Delete File:`, with `+`/`-` lines.
enum ApplyPatch {
    static func edits(in patch: String, cwd: String) -> [FileEdit] {
        var edits: [FileEdit] = []
        func path(_ line: String, after marker: String) -> String {
            let raw = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return raw.hasPrefix("/") ? raw : (cwd as NSString).appendingPathComponent(raw)
        }

        for line in patch.lines {
            if line.hasPrefix("*** Add File: ") {
                edits.append(FileEdit(path: path(line, after: "*** Add File: "), change: .added))
            } else if line.hasPrefix("*** Update File: ") {
                edits.append(FileEdit(path: path(line, after: "*** Update File: "), change: .modified))
            } else if line.hasPrefix("*** Delete File: ") {
                edits.append(FileEdit(path: path(line, after: "*** Delete File: "), change: .deleted))
            } else if line.hasPrefix("*** Move to: "), !edits.isEmpty {
                edits[edits.count - 1].movedTo = path(line, after: "*** Move to: ")
            } else if line.hasPrefix("***") || line.hasPrefix("@@") || edits.isEmpty {
                continue
            } else if line.hasPrefix("+") {
                edits[edits.count - 1].added.append(String(line.dropFirst()))
            } else if line.hasPrefix("-") {
                edits[edits.count - 1].removed.append(String(line.dropFirst()))
            }
        }
        return edits.map {
            var edit = $0
            edit.added = Caps.lines(edit.added)
            edit.removed = Caps.lines(edit.removed)
            return edit
        }
    }
}
