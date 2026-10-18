import Foundation

/// Holds events while the app isn't running. The hook appends; the app drains on launch.
public enum Spool {
    private static let maximumFileBytes: off_t = 64 * 1024 * 1024

    /// Appends one event. The return value is false if the event could not be
    /// persisted in full.
    @discardableResult
    public static func append(_ line: Data, in directory: URL = MeanwhilePaths.spool) -> Bool {
        guard let lockFD = lock(directory: directory, name: ".append-lock") else { return false }
        defer {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }

        let file = directory.appendingPathComponent("events.ndjson").path
        let fd = open(file, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              fchmod(fd, 0o600) == 0 else { return false }

        // Keep the file newline-delimited even if a caller omits the terminator.
        var framedLine = line
        if framedLine.last != 0x0A { framedLine.append(0x0A) }
        let originalLength = status.st_size
        guard framedLine.count <= Wire.maximumLineBytes + 1,
              originalLength <= maximumFileBytes - off_t(framedLine.count) else { return false }

        return framedLine.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var written = 0
            while written < bytes.count {
                let count = write(fd, base + written, bytes.count - written)
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    // No other appender can have advanced the file while the lock
                    // is held, so it is safe to discard our incomplete record.
                    _ = ftruncate(fd, originalLength)
                    return false
                }
            }
            return true
        }
    }

    /// Returns every spooled line, oldest first, and empties the spool.
    public static func drain(in directory: URL = MeanwhilePaths.spool) -> [Data] {
        // Serialize drainers, but only hold the append lock for the rename. Hooks
        // therefore do not wait while a large claimed spool is read from disk.
        guard let drainFD = lock(directory: directory, name: ".drain-lock") else { return [] }
        defer {
            flock(drainFD, LOCK_UN)
            close(drainFD)
        }

        let file = directory.appendingPathComponent("events.ndjson")
        let claimed = directory.appendingPathComponent("draining-\(UUID().uuidString).ndjson")

        // The lock prevents an appender from retaining the old inode while it is
        // renamed and read. Without it, that late write would go to an unlinked
        // file and the event would be lost.
        guard let appendFD = lock(directory: directory, name: ".append-lock") else { return [] }
        let renameResult = rename(file.path, claimed.path)
        let renameError = errno
        flock(appendFD, LOCK_UN)
        close(appendFD)
        if renameResult != 0, renameError != ENOENT { return [] }

        // Include claims left by a process that died between rename and removal.
        // Sorting by creation/modification date preserves their order as closely
        // as the filesystem permits; each individual file remains strictly ordered.
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        let pending = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("draining-") && $0.pathExtension == "ndjson" }
            .sorted {
                let left = try? $0.resourceValues(forKeys: keys)
                let right = try? $1.resourceValues(forKeys: keys)
                let leftDate = left?.creationDate ?? left?.contentModificationDate ?? .distantPast
                let rightDate = right?.creationDate ?? right?.contentModificationDate ?? .distantPast
                if leftDate != rightDate { return leftDate < rightDate }
                return $0.lastPathComponent < $1.lastPathComponent
            }

        var lines: [Data] = []
        var remainingBytes = Int(maximumFileBytes)
        for pendingFile in pending {
            guard let data = readRegularFile(at: pendingFile, maximumBytes: remainingBytes) else { continue }
            remainingBytes -= data.count
            lines.append(contentsOf: data.split(separator: 0x0A)
                .filter { $0.count <= Wire.maximumLineBytes }
                .map { Data($0) })
            try? FileManager.default.removeItem(at: pendingFile)
        }
        return lines
    }

    /// Opens and exclusively locks the per-spool lock file. All mutation of the
    /// active and claimed files happens under this cross-process lock.
    private static func lock(directory: URL, name: String) -> Int32? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return nil
        }

        let fd = open(
            directory.appendingPathComponent(name).path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            0o600
        )
        guard fd >= 0 else { return nil }
        var status = stat()
        guard fstat(fd, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              fchmod(fd, 0o600) == 0 else {
            close(fd)
            return nil
        }

        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            close(fd)
            return nil
        }
        return fd
    }

    private static func readRegularFile(at url: URL, maximumBytes: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var status = stat()
        guard fstat(fd, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              status.st_size <= off_t(maximumBytes) else {
            close(fd)
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return try? handle.readToEnd() ?? Data()
    }
}
