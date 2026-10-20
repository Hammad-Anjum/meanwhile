import Foundation

/// What `meanwhile uninstall --purge` deletes besides the hooks and the launch agent:
/// every folder Meanwhile writes its own data to.
public enum Purge {
    /// The data folders for `home`: databases, spool, debug recordings and installed
    /// binaries; settings (under `XDG_CONFIG_HOME` when that is an absolute path, as
    /// `UserSettings.defaultURL` reads it); and logs.
    public static func targets(home: URL, environment: [String: String]) -> [URL] {
        let configBase = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".config")
        return [
            home.appendingPathComponent("Library/Application Support/Meanwhile", isDirectory: true),
            configBase.appendingPathComponent("meanwhile", isDirectory: true),
            home.appendingPathComponent("Library/Logs/Meanwhile", isDirectory: true),
        ]
    }

    /// The targets that exist, with their size in bytes.
    public static func existing(_ targets: [URL]) -> [(url: URL, bytes: Int64)] {
        targets.filter { FileManager.default.fileExists(atPath: $0.path) }.map { ($0, size(of: $0)) }
    }

    /// Total size of the files under `url`, not following symlinks.
    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Deletes each target. Missing ones are not an error.
    public static func remove(_ targets: [URL]) throws {
        for url in targets where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
