import Foundation

/// Runs a command and collects its output, with a time limit. For git and the agent CLIs.
public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: String
        public let timedOut: Bool

        public var succeeded: Bool { status == 0 && !timedOut }
        public var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// Runs `executable` (an absolute path, or a name found on PATH). Stdin is `input`, or
    /// closed when there is none.
    public static func run(_ executable: String, _ arguments: [String], in directory: String? = nil,
                           environment: [String: String]? = nil, input: Data? = nil,
                           timeout: TimeInterval = 30, maximumOutputBytes: Int = 256 * 1024 * 1024) throws -> Result {
        let process = Process()
        let resolvedExecutable = executable == "git" ? "/usr/bin/git" : executable
        if resolvedExecutable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: resolvedExecutable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [resolvedExecutable] + arguments
        }
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Agent CLIs wait forever on an open stdin pipe (found in the 0.5 spike).
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice

        // Read both pipes while the process runs, so a large output can't fill a pipe and stall it.
        // Dedicated threads, not GCD: these block until the process exits, and with many runs
        // at once (the worker, parallel tests) blocked GCD workers exhausted its thread pool
        // and the reads that would unblock them never got a thread (found 2026-10-19).
        let collected = Collected(maximumBytes: maximumOutputBytes)
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            Thread.detachNewThread {
                while let data = try? pipe.fileHandleForReading.read(upToCount: 64 * 1024), !data.isEmpty {
                    collected.append(data, isOut: isOut)
                }
                group.leave()
            }
        }

        try process.run()
        // Put descendants in the same group where possible, so a timeout also kills children
        // that inherited our stdout/stderr pipes.
        _ = setpgid(process.processIdentifier, process.processIdentifier)
        if let stdin, let input {
            // Write on another thread: a large input can fill the pipe before the reader starts.
            Thread.detachNewThread {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() > deadline {
                timedOut = true
                kill(-process.processIdentifier, SIGTERM)
                process.terminate()
                break
            }
            usleep(20_000)
        }
        if timedOut {
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < grace { usleep(20_000) }
            if process.isRunning {
                kill(-process.processIdentifier, SIGKILL)
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        group.wait()
        return Result(status: process.terminationStatus, stdout: collected.out,
                      stderr: String(decoding: collected.err, as: UTF8.self), timedOut: timedOut)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()
        private let maximumBytes: Int
        init(maximumBytes: Int) { self.maximumBytes = max(0, maximumBytes) }
        var out: Data { lock.withLock { outData } }
        var err: Data { lock.withLock { errData } }
        func append(_ data: Data, isOut: Bool) {
            lock.withLock {
                if isOut {
                    if outData.count < maximumBytes { outData.append(data.prefix(maximumBytes - outData.count)) }
                } else if errData.count < maximumBytes {
                    errData.append(data.prefix(maximumBytes - errData.count))
                }
            }
        }
    }
}
