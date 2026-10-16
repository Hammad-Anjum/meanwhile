import Foundation

/// Holds events while the app isn't running. The hook appends; the app drains on launch.
public enum Spool {
    public static func append(_ line: Data, in directory: URL = MeanwhilePaths.spool) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("events.ndjson").path
        let fd = open(file, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Returns every spooled line, oldest first, and empties the spool.
    public static func drain(in directory: URL = MeanwhilePaths.spool) -> [Data] {
        let file = directory.appendingPathComponent("events.ndjson")
        // Rename first, so a hook writing at the same moment starts a fresh file.
        let claimed = directory.appendingPathComponent("draining-\(UUID().uuidString).ndjson")
        guard (try? FileManager.default.moveItem(at: file, to: claimed)) != nil,
              let data = try? Data(contentsOf: claimed) else { return [] }
        try? FileManager.default.removeItem(at: claimed)
        return data.split(separator: 0x0A).map { Data($0) }
    }
}
