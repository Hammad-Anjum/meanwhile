import Foundation
import Testing
import MeanwhileIPC

@Test func spoolFramesLinesWhoseNewlineWasOmitted() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mw-spool-framing-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(Spool.append(Data("one".utf8), in: directory))
    #expect(Spool.append(Data("two\n".utf8), in: directory))
    #expect(Spool.drain(in: directory).map { String(decoding: $0, as: UTF8.self) } == ["one", "two"])
}

@Test func concurrentSpoolAppendAndDrainDoesNotLoseOrMergeRecords() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mw-spool-concurrent-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let count = 200
    let appenders = DispatchGroup()
    for index in 0..<count {
        appenders.enter()
        DispatchQueue.global().async {
            Spool.append(Data("event-\(index)".utf8), in: directory)
            appenders.leave()
        }
    }

    var received: [Data] = []
    while appenders.wait(timeout: .now()) == .timedOut {
        received.append(contentsOf: Spool.drain(in: directory))
    }
    received.append(contentsOf: Spool.drain(in: directory))

    let strings = received.map { String(decoding: $0, as: UTF8.self) }
    #expect(strings.count == count)
    #expect(Set(strings) == Set((0..<count).map { "event-\($0)" }))
}

@Test func unixSocketAddressRejectsEmbeddedNull() {
    #expect(UnixSocket.address("/tmp/valid\0ignored.sock") == nil)
}
