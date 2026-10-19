import Foundation

/// File locations shared by the app and `meanwhile-hook`.
public enum MeanwhilePaths {
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Meanwhile", isDirectory: true)
    }

    /// Unix socket the hook writes events to. Must stay under 104 bytes (sockaddr_un limit).
    public static var socket: URL { supportDirectory.appendingPathComponent("meanwhile.sock") }

    /// Events written here while the app is not running; drained on launch.
    public static var spool: URL { supportDirectory.appendingPathComponent("spool", isDirectory: true) }

    /// SQLite store of received events (task 1.2).
    public static var eventStore: URL { supportDirectory.appendingPathComponent("meanwhile.sqlite") }

    /// Card progress and the answer log (task 1.5). Never pruned.
    public static var reviewStore: URL { supportDirectory.appendingPathComponent("reviews.sqlite") }

    /// Every event the app receives, as raw lines. Used to record test fixtures (task 0.3).
    public static var debugRecording: URL {
        supportDirectory.appendingPathComponent("debug/events.ndjson")
    }
}
