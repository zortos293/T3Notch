import Foundation
import os

public enum FileWatchingError: Error, Sendable {
    case cannotOpen(path: String, code: Int32)
}

/// Fires when a directory's entries change (create/delete/rename). Coalesced,
/// so a burst of writes produces one callback.
public final class DirectoryWatcher: @unchecked Sendable {
    private struct State: Sendable {
        var source: (any DispatchSourceFileSystemObject)?
        var pending = false
        var stopped = false
    }

    private let url: URL
    private let queue: DispatchQueue
    private let debounce: Duration
    private let onChange: @Sendable () -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(
        url: URL,
        queue: DispatchQueue,
        debounce: Duration = .milliseconds(100),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func start() throws {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            throw FileWatchingError.cannotOpen(path: url.path, code: errno)
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }

        let previous: (any DispatchSourceFileSystemObject)? = state.withLock { state in
            guard !state.stopped else { return source }
            let previous = state.source
            state.source = source
            return previous
        }
        previous?.cancel()
        source.activate()
    }

    public func stop() {
        let source: (any DispatchSourceFileSystemObject)? = state.withLock { state in
            state.stopped = true
            let source = state.source
            state.source = nil
            return source
        }
        source?.cancel()
    }

    private func schedule() {
        let shouldSchedule = state.withLock { state -> Bool in
            guard !state.stopped, !state.pending else { return false }
            state.pending = true
            return true
        }
        guard shouldSchedule else { return }

        queue.asyncAfter(deadline: .now() + debounce.seconds) { [weak self] in
            guard let self else { return }
            let fire = state.withLock { state -> Bool in
                state.pending = false
                return !state.stopped
            }
            if fire { onChange() }
        }
    }
}

/// Incremental JSONL reader: byte-offset tracking, partial-line buffering,
/// truncation reset, reopen-on-rename. One instance per file. All file IO runs
/// on `queue`, which must be serial.
public final class JSONLTailer: @unchecked Sendable {
    private struct State: Sendable {
        var fd: Int32 = -1
        var source: (any DispatchSourceFileSystemObject)?
        var offset: off_t = 0
        var partial = Data()
        var reopenAttempts = 0
        var started = false
        var stopped = false
    }

    /// A recreated file usually shows up within a second; past that the owning
    /// transport is told to drop the tailer instead of retrying forever.
    private static let maxReopenAttempts = 8
    private static let reopenDelay: DispatchTimeInterval = .milliseconds(150)

    private let url: URL
    private let queue: DispatchQueue
    private let onLines: @Sendable ([Data]) -> Void
    private let onEnded: (@Sendable () -> Void)?
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(
        url: URL,
        queue: DispatchQueue,
        onLines: @escaping @Sendable ([Data]) -> Void,
        onEnded: (@Sendable () -> Void)? = nil
    ) {
        self.url = url
        self.queue = queue
        self.onLines = onLines
        self.onEnded = onEnded
    }

    deinit {
        stop()
    }

    /// Reads the whole file first, then follows appends.
    public func start() {
        let shouldStart = state.withLock { state -> Bool in
            guard !state.stopped, !state.started else { return false }
            state.started = true
            return true
        }
        guard shouldStart else { return }
        queue.async { [weak self] in self?.openAndRead() }
    }

    /// Forces an immediate read; also retries the open when the file was missing.
    public func poke() {
        queue.async { [weak self] in
            guard let self else { return }
            if state.withLock(\.fd) < 0 {
                openAndRead()
            } else {
                readAvailable()
            }
        }
    }

    public func stop() {
        let source: (any DispatchSourceFileSystemObject)? = state.withLock { state in
            state.stopped = true
            let source = state.source
            state.source = nil
            state.fd = -1
            return source
        }
        source?.cancel()
    }

    // MARK: - Queue-confined work

    private func openAndRead() {
        guard !state.withLock(\.stopped) else { return }

        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            scheduleReopen()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let data = source.data
            if data.contains(.delete) || data.contains(.rename) {
                reopen()
            } else {
                readAvailable()
            }
        }
        source.setCancelHandler { close(fd) }

        let previous: (any DispatchSourceFileSystemObject)? = state.withLock { state in
            guard !state.stopped else { return source }
            let previous = state.source
            state.fd = fd
            state.source = source
            state.offset = 0
            state.partial = Data()
            state.reopenAttempts = 0
            return previous
        }
        previous?.cancel()
        source.activate()

        readAvailable()
    }

    private func reopen() {
        let source: (any DispatchSourceFileSystemObject)? = state.withLock { state in
            let source = state.source
            state.source = nil
            state.fd = -1
            return source
        }
        source?.cancel()
        openAndRead()
    }

    private func scheduleReopen() {
        let attempts = state.withLock { state -> Int in
            guard !state.stopped else { return Self.maxReopenAttempts }
            state.reopenAttempts += 1
            return state.reopenAttempts
        }
        guard attempts < Self.maxReopenAttempts else {
            onEnded?()
            return
        }
        queue.asyncAfter(deadline: .now() + Self.reopenDelay) { [weak self] in
            guard let self, !state.withLock(\.stopped) else { return }
            openAndRead()
        }
    }

    private func readAvailable() {
        let fd = state.withLock(\.fd)
        guard fd >= 0 else { return }

        var info = stat()
        guard fstat(fd, &info) == 0 else { return }
        let size = info.st_size

        // A rewritten file (compaction, `/clear`) shrinks; replay it from zero.
        let startOffset = state.withLock { state -> off_t in
            if size < state.offset {
                state.offset = 0
                state.partial = Data()
            }
            return state.offset
        }
        guard size > startOffset else { return }

        guard lseek(fd, startOffset, SEEK_SET) >= 0 else { return }
        var read = Data()
        var offset = startOffset
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                read.append(contentsOf: buffer[0..<count])
                offset += off_t(count)
            } else {
                break
            }
        }
        guard !read.isEmpty else { return }
        let chunk = read
        let endOffset = offset

        let lines: [Data] = state.withLock { state in
            state.offset = endOffset
            var pending = state.partial
            pending.append(chunk)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                if !line.isEmpty { lines.append(Data(line)) }
                pending = pending[pending.index(after: newline)...]
            }
            state.partial = Data(pending)
            return lines
        }

        if !lines.isEmpty { onLines(lines) }
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
