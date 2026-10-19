import Foundation

public enum UnixSocket {
    /// Builds a `sockaddr_un` for `path`, or nil if the path is too long.
    public static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// Pauses before each retry of a refused connection. On macOS a Unix socket whose
    /// accept backlog is full refuses at once instead of waiting, so a burst of hook
    /// events (parallel tool calls) would otherwise fall through to the spool.
    private static let connectRetryDelays: [useconds_t] = [5_000, 20_000, 50_000]

    /// Sends `data` to the socket at `path`. Returns false if nothing is listening
    /// or the write fails; never blocks for more than about a second.
    public static func send(_ data: Data, to path: String) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        var fd = connected(to: path, deadline: deadline)
        for delay in connectRetryDelays where fd.descriptor < 0 && fd.retryable {
            usleep(delay)
            fd = connected(to: path, deadline: deadline)
        }
        guard fd.descriptor >= 0 else { return false }
        let descriptor = fd.descriptor
        defer { close(descriptor) }
        return writeAll(data, to: descriptor, deadline: deadline)
    }

    /// A connected non-blocking socket, or -1 and whether trying again could help.
    private static func connected(to path: String, deadline: UInt64) -> (descriptor: Int32, retryable: Bool) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return (-1, false) }

        var on: Int32 = 1
        let flags = fcntl(fd, F_GETFL)
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
              flags >= 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              var address = address(path) else {
            close(fd)
            return (-1, false)
        }
        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            let code = errno
            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard code == EINPROGRESS, waitUntilWritable(fd, deadline: deadline),
                  getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0,
                  socketError == 0 else {
                close(fd)
                // ENOENT (no socket file: the app isn't running) fails fast.
                return (-1, code == ECONNREFUSED || code == EAGAIN)
            }
        }
        return (fd, false)
    }

    private static func writeAll(_ data: Data, to fd: Int32, deadline: UInt64) -> Bool {
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var sent = 0
            while sent < buffer.count {
                let n = write(fd, base + sent, buffer.count - sent)
                if n > 0 {
                    sent += n
                } else if n < 0, errno == EINTR {
                    continue
                } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard waitUntilWritable(fd, deadline: deadline) else { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func waitUntilWritable(_ fd: Int32, deadline: UInt64) -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let remaining = deadline - now
            let milliseconds = Int32(min((remaining + 999_999) / 1_000_000, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let result = poll(&descriptor, 1, milliseconds)
            if result > 0 {
                return descriptor.revents & Int16(POLLOUT) != 0
                    && descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0
            }
            if result < 0, errno == EINTR { continue }
            return false
        }
    }
}
