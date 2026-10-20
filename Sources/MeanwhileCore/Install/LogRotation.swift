import Foundation

/// Keeps the login item's log bounded. launchd opens the log before `meanwhile run` starts
/// and the process writes to it with O_APPEND, so renaming the file would leave it writing
/// to the renamed one. Instead the tail is copied aside and the file is truncated in place;
/// O_APPEND writers carry on at the new end.
public enum LogRotation {
    /// Rotate once the log is bigger than this.
    public static let defaultLimit = 5 * 1024 * 1024
    /// How much of the end to keep in `<log>.1`.
    public static let defaultKeep = 1024 * 1024

    /// If the file at `url` is larger than `limit` bytes, writes its last `keep` bytes
    /// (from the first full line) to `<name>.1`, replacing the old one, and truncates the
    /// file to zero. Returns whether it rotated. A missing file is not an error.
    @discardableResult
    public static func rotateIfNeeded(at url: URL, limit: Int = defaultLimit, keep: Int = defaultKeep) throws -> Bool {
        let path = url.path
        var info = stat()
        guard stat(path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_size > limit else { return false }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let start = max(0, Int(info.st_size) - keep)
        try handle.seek(toOffset: UInt64(start))
        var tail = try handle.read(upToCount: Int(info.st_size) - start) ?? Data()
        // Start the kept part on a line boundary.
        if start > 0, let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail.suffix(from: tail.index(after: newline))
        }

        let rotated = path + ".1"
        let temporary = rotated + ".tmp"
        try? FileManager.default.removeItem(atPath: temporary)
        guard FileManager.default.createFile(atPath: temporary, contents: tail, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary])
        }
        guard rename(temporary, rotated) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(atPath: temporary)
            throw error
        }
        // Lines written between the read and here are lost; at most a few.
        guard truncate(path, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return true
    }
}
