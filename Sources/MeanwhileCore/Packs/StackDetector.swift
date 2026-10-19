import Foundation

/// Works out which stacks a repo uses from its build files, so stack decks follow
/// the repo being worked on. Looks at the repo root and one level down (monorepos).
public enum StackDetector {
    /// The enclosing git repo's root, or `cwd` itself when it isn't in one.
    public static func repoRoot(for cwd: String) -> String {
        var directory = URL(fileURLWithPath: cwd).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        while directory.path != "/" && directory.path != home {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory.path
            }
            directory.deleteLastPathComponent()
        }
        return cwd
    }

    public static func stacks(inRepo root: String) -> Set<Stack> {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        var directories = [rootURL]
        if let children = try? fileManager.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            directories += children.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && !["node_modules", "build", "dist", "Pods", "vendor"].contains($0.lastPathComponent)
            }
        }

        var stacks = Set<Stack>()
        for directory in directories {
            let names = Set((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            func has(_ name: String) -> Bool { names.contains(name) }

            if has("Package.swift") || names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                stacks.insert(.swift)
            }
            if has("pyproject.toml") || has("requirements.txt") || has("setup.py") || has("Pipfile") {
                stacks.insert(.python)
            }
            if has("go.mod") { stacks.insert(.go) }
            if has("Cargo.toml") { stacks.insert(.rust) }
            if has("tsconfig.json") { stacks.insert(.typescript) }
            if has("package.json") {
                stacks.insert(.javascript)
                let dependencies = packageDependencies(directory.appendingPathComponent("package.json"))
                if dependencies.contains("typescript") { stacks.insert(.typescript) }
                if dependencies.contains("react") { stacks.insert(.react) }
            }
        }
        return stacks
    }

    private static func packageDependencies(_ url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let sections = ["dependencies", "devDependencies", "peerDependencies"]
        return Set(sections.flatMap { (object[$0] as? [String: Any])?.keys.map { $0 } ?? [] })
    }
}
