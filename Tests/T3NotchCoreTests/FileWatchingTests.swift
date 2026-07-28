import Foundation
import Testing
import os
@testable import T3NotchCore

private final class LineCollector: @unchecked Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: [String]())

    var collected: [String] { lines.withLock { $0 } }

    func append(_ data: [Data]) {
        let decoded = data.map { String(decoding: $0, as: UTF8.self) }
        lines.withLock { $0.append(contentsOf: decoded) }
    }

    func reset() {
        lines.withLock { $0.removeAll() }
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)

    var count: Int { value.withLock { $0 } }

    func bump() {
        value.withLock { $0 += 1 }
    }
}

/// Kqueue delivery is asynchronous, so assertions poll instead of sleeping a
/// fixed amount.
private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("filewatching-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func append(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

@Suite("FileWatching")
struct FileWatchingTests {
    @Test func tailerReadsExistingContentThenAppends() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("log.jsonl")
        try Data((#"{"a":1}"# + "\n").utf8).write(to: file)

        let collector = LineCollector()
        let tailer = JSONLTailer(
            url: file,
            queue: DispatchQueue(label: "test.tailer.append"),
            onLines: { collector.append($0) }
        )
        tailer.start()
        defer { tailer.stop() }

        #expect(await waitUntil { collector.collected == [#"{"a":1}"#] })

        try append(#"{"a":2}"# + "\n", to: file)
        #expect(await waitUntil { collector.collected.count == 2 })
        #expect(collector.collected.last == #"{"a":2}"#)

        try append(#"{"a":3}"# + "\n" + #"{"a":4}"# + "\n", to: file)
        #expect(await waitUntil { collector.collected.count == 4 })
        #expect(collector.collected == [#"{"a":1}"#, #"{"a":2}"#, #"{"a":3}"#, #"{"a":4}"#])
    }

    @Test func tailerBuffersLineSplitAcrossWrites() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("split.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)

        let collector = LineCollector()
        let tailer = JSONLTailer(
            url: file,
            queue: DispatchQueue(label: "test.tailer.split"),
            onLines: { collector.append($0) }
        )
        tailer.start()
        defer { tailer.stop() }

        try append(#"{"half":"fir"#, to: file)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(collector.collected.isEmpty)

        try append("st\"}\n", to: file)
        #expect(await waitUntil { collector.collected.count == 1 })
        #expect(collector.collected.first == #"{"half":"first"}"#)
    }

    @Test func tailerResetsAfterTruncation() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("truncated.jsonl")
        try Data("one\ntwo\nthree\n".utf8).write(to: file)

        let collector = LineCollector()
        let tailer = JSONLTailer(
            url: file,
            queue: DispatchQueue(label: "test.tailer.truncate"),
            onLines: { collector.append($0) }
        )
        tailer.start()
        defer { tailer.stop() }

        #expect(await waitUntil { collector.collected.count == 3 })
        collector.reset()

        // Same inode, shorter content: the tailer must replay from zero instead
        // of waiting for the file to grow past the old offset.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("fresh\n".utf8))
        try handle.close()

        #expect(await waitUntil { collector.collected == ["fresh"] })
    }

    @Test func tailerReopensAfterDeleteAndRecreate() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("recreated.jsonl")
        try Data("before\n".utf8).write(to: file)

        let collector = LineCollector()
        let tailer = JSONLTailer(
            url: file,
            queue: DispatchQueue(label: "test.tailer.recreate"),
            onLines: { collector.append($0) }
        )
        tailer.start()
        defer { tailer.stop() }

        #expect(await waitUntil { collector.collected == ["before"] })
        collector.reset()

        try FileManager.default.removeItem(at: file)
        try Data("after\n".utf8).write(to: file)

        #expect(await waitUntil { collector.collected == ["after"] })
    }

    @Test func directoryWatcherFiresOnNewEntries() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let counter = ChangeCounter()
        let watcher = DirectoryWatcher(
            url: directory,
            queue: DispatchQueue(label: "test.dirwatcher"),
            onChange: { counter.bump() }
        )
        try watcher.start()
        defer { watcher.stop() }

        try Data("{}".utf8).write(to: directory.appendingPathComponent("1234.json"))
        #expect(await waitUntil { counter.count >= 1 })

        try FileManager.default.removeItem(at: directory.appendingPathComponent("1234.json"))
        #expect(await waitUntil { counter.count >= 2 })
    }
}
