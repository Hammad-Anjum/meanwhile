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

    /// Sends `data` to the socket at `path`. Returns false if nothing is listening
    /// or the write fails; never blocks for more than about a second.
    public static func send(_ data: Data, to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var on: Int32 = 1
        let flags = fcntl(fd, F_GETFL)
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
              flags >= 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }

        guard var address = address(path) else { return false }
        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        if connectResult != 0 {
            guard errno == EINPROGRESS, waitUntilWritable(fd, deadline: deadline) else { return false }
            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0,
                  socketError == 0 else { return false }
        }

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
