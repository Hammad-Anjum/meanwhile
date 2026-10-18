import Foundation
import MeanwhileIPC

public enum EventServerError: Error {
    case socket(Int32)
    case pathTooLong
    case alreadyRunning
    case pathOccupied
    case pathAccess(Int32)
    case bind(Int32)
    case permissions(Int32)
    case listen(Int32)
    case configure(Int32)
}

/// Listens on the Unix socket and hands each received line to `onLine`, on a background queue.
public final class EventServer: @unchecked Sendable {
    private struct SocketIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private let path: String
    private let onLine: @Sendable (Data) -> Void
    private let maximumLineBytes: Int
    private let clientSlots: DispatchSemaphore
    private let clientQueue = DispatchQueue(label: "dev.meanwhile.event-server.clients", qos: .utility)
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var socketIdentity: SocketIdentity?
    private var acceptFinished: DispatchSemaphore?
    private var isStopping = false

    public init(
        path: String = MeanwhilePaths.socket.path,
        maximumLineBytes: Int = 16 * 1024 * 1024,
        maximumPendingClients: Int = 32,
        onLine: @escaping @Sendable (Data) -> Void
    ) {
        precondition(maximumLineBytes > 0, "maximumLineBytes must be positive")
        precondition(maximumPendingClients > 0, "maximumPendingClients must be positive")
        self.path = path
        self.maximumLineBytes = maximumLineBytes
        self.clientSlots = DispatchSemaphore(value: maximumPendingClients)
        self.onLine = onLine
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }

        guard listenFD < 0, !isStopping else { throw EventServerError.alreadyRunning }
        guard var address = UnixSocket.address(path) else { throw EventServerError.pathTooLong }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try removeStaleSocketIfSafe()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EventServerError.socket(errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw EventServerError.bind(code)
        }
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw EventServerError.permissions(code)
        }
        guard listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw EventServerError.listen(code)
        }
        let currentFlags = fcntl(fd, F_GETFL)
        guard currentFlags >= 0, fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw EventServerError.configure(code)
        }

        listenFD = fd
        socketIdentity = Self.identity(of: path)
        let onLine = self.onLine
        let maximumLineBytes = self.maximumLineBytes
        let clientSlots = self.clientSlots
        let clientQueue = self.clientQueue
        let finished = DispatchSemaphore(value: 0)
        acceptFinished = finished
        Thread.detachNewThread { [weak self] in
            defer {
                self?.acceptLoopDidFinish(fd: fd)
                close(fd)
                finished.signal()
            }
            while self?.isListening(on: fd) == true {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 25)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if ready == 0 { continue }
                guard self?.isListening(on: fd) == true else { return }
                guard descriptor.revents & Int16(POLLIN) != 0 else { return }
                // Reserve capacity before accept. Leaving excess connections in the
                // kernel backlog applies backpressure; accepting and then closing
                // them could make a sender report success even though its event was lost.
                guard clientSlots.wait(timeout: .now() + .milliseconds(25)) == .success else { continue }
                guard self?.isListening(on: fd) == true else {
                    clientSlots.signal()
                    return
                }
                let client = accept(fd, nil, nil)
                if client < 0 {
                    clientSlots.signal()
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    return
                }
                clientQueue.async {
                    defer { clientSlots.signal() }
                    Self.readLines(from: client, maximumLineBytes: maximumLineBytes, onLine: onLine)
                }
            }
        }
    }

    public func stop() {
        lock.lock()
        guard listenFD >= 0, !isStopping else {
            lock.unlock()
            return
        }
        isStopping = true
        let finished = acceptFinished
        listenFD = -1
        lock.unlock()

        // The accept thread owns and closes the descriptor. Waiting here prevents a
        // rapid restart from reusing its descriptor while the old loop is still alive.
        finished?.wait()

        lock.withLock {
            if let expected = socketIdentity, Self.identity(of: path) == expected {
                unlink(path)
            }
            socketIdentity = nil
            acceptFinished = nil
            isStopping = false
        }
    }

    deinit { stop() }

    /// Removes only a dead socket owned by this user. In particular, never delete a
    /// regular file, symlink, another user's socket, or a socket with a live listener.
    private func removeStaleSocketIfSafe() throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw EventServerError.pathAccess(errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_uid == geteuid(),
              !Self.hasLiveListener(at: path)
        else { throw EventServerError.pathOccupied }
        guard unlink(path) == 0 else { throw EventServerError.pathAccess(errno) }
    }

    private static func hasLiveListener(at path: String) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return true }
        defer { close(probe) }
        guard var address = UnixSocket.address(path) else { return true }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }
        // ECONNREFUSED is the expected result for an orphan left by a crashed process.
        // Treat every other failure conservatively so an ambiguous path is not deleted.
        return errno != ECONNREFUSED
    }

    private static func identity(of path: String) -> SocketIdentity? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return nil }
        return SocketIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private func acceptLoopDidFinish(fd: Int32) {
        lock.withLock {
            if listenFD == fd {
                listenFD = -1
                acceptFinished = nil
            }
        }
    }

    private func isListening(on fd: Int32) -> Bool {
        lock.withLock { listenFD == fd && !isStopping }
    }

    private static func readLines(
        from client: Int32,
        maximumLineBytes: Int,
        onLine: @Sendable (Data) -> Void
    ) {
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
                guard line.count <= maximumLineBytes else { return }
                if !line.isEmpty { onLine(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            guard buffer.count <= maximumLineBytes else { return }
        }
        if !buffer.isEmpty, buffer.count <= maximumLineBytes { onLine(buffer) }
    }
}
