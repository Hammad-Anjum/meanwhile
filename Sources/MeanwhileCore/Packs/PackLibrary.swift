import Foundation

/// The packs Meanwhile knows about, and which of them apply to a repo.
public struct PackLibrary: Sendable {
    public let packs: [Pack]

    public init(packs: [Pack]) {
        self.packs = packs.sorted { ($0.kind.rawValue, $0.title) < ($1.kind.rawValue, $1.title) }
    }

    /// The SwiftPM resource bundle, looked up next to the executable first. Under launchd
    /// (`meanwhile setup`'s login item) SwiftPM's generated `Bundle.module` traps on a nil
    /// `Bundle.main.bundleURL` (seen 2026-10-19); tests run inside xctest and use `Bundle.module`.
    static var resources: Bundle {
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let beside = executable.deletingLastPathComponent().appendingPathComponent("MeanwhileKit_MeanwhileCore.bundle")
        return Bundle(url: beside) ?? Bundle.module
    }

    /// The packs that ship with Meanwhile. Invalid files are skipped and reported in `failures`.
    public static func bundled() -> (library: PackLibrary, failures: [String]) {
        let urls = resources.urls(forResourcesWithExtension: "json", subdirectory: "Packs") ?? []
        var packs: [Pack] = []
        var failures: [String] = []
        for url in urls {
            do {
                let pack = try JSONDecoder().decode(Pack.self, from: Data(contentsOf: url))
                let problems = pack.problems()
                if problems.isEmpty { packs.append(pack) }
                else { failures.append("\(url.lastPathComponent): \(problems.joined(separator: "; "))") }
            } catch {
                failures.append("\(url.lastPathComponent): \(error)")
            }
        }
        return (PackLibrary(packs: packs), failures)
    }

    /// Generic packs that are on, plus stack packs matching the repo's stacks that are on.
    public func packs(disabled: Set<String>, stacks: Set<Stack>) -> [Pack] {
        packs.filter { pack in
            guard !disabled.contains(pack.id) else { return false }
            return pack.kind == .generic || !stacks.isDisjoint(with: pack.stacks)
        }
    }

    /// Convenience for the app: the packs for the repo containing `cwd`.
    public func packs(forDirectory cwd: String, disabled: Set<String>) -> [Pack] {
        packs(disabled: disabled, stacks: StackDetector.stacks(inRepo: StackDetector.repoRoot(for: cwd)))
    }
}
