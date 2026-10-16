import Foundation
import MeanwhileIPC

public enum EventServerError: Error {
    case socket(Int32)
    case pathTooLong
    case bind(Int32)
    case listen(Int32)
}

/// Listens on the Unix socket and hands each received line to `onLine`, on a background queue.
public final class EventServer: @unchecked Sendable {
    private let path: String
    private let onLine: @Sendable (Data) -> Void
    private let lock = NSLock()
    private var listenFD: Int32 = -1

    public init(path: String = MeanwhilePaths.socket.path, onLine: @escaping @Sendable (Data) -> Void) {
        self.path = path
        self.onLine = onLine
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path) // stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EventServerError.socket(errno) }
        guard var address = UnixSocket.address(path) else { close(fd); throw EventServerError.pathTooLong }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); throw EventServerError.bind(errno) }
        chmod(path, 0o600) // only this user can send events
        guard listen(fd, 64) == 0 else { close(fd); throw EventServerError.listen(errno) }

        lock.withLock { listenFD = fd }
        let onLine = self.onLine
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return // socket closed by stop()
                }
                DispatchQueue.global(qos: .utility).async { Self.readLines(from: client, onLine: onLine) }
            }
        }
    }

    public func stop() {
        lock.withLock {
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
        }
        unlink(path)
    }

    private static func readLines(from client: Int32, onLine: @Sendable (Data) -> Void) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                if !line.isEmpty { onLine(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !buffer.isEmpty { onLine(buffer) }
    }
}
