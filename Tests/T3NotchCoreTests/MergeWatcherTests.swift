import Foundation
import Testing
@testable import T3NotchCore

@Suite("MergeWatcher")
struct MergeWatcherTests {
    @Test func reportsBranchesOnlyOnceTheyLand() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }

        try repository.git("checkout", "-q", "-b", "feature/landed")
        try repository.commit(file: "b.txt", message: "work")
        try repository.git("checkout", "-q", "-b", "feature/open", "main")
        try repository.commit(file: "c.txt", message: "open work")
        try repository.git("checkout", "-q", "main")

        let watcher = MergeWatcher(forge: .silent)
        let targets = [
            MergeWatcher.Target(
                threadId: "t-landed",
                branch: "feature/landed",
                repositoryRoot: repository.path
            ),
            MergeWatcher.Target(
                threadId: "t-open",
                branch: "feature/open",
                repositoryRoot: repository.path
            ),
        ]

        // Outstanding branches are recorded, not reported.
        #expect(await watcher.newlyMerged(among: targets).isEmpty)
        #expect(await watcher.newlyMerged(among: targets).isEmpty)

        try repository.git("merge", "-q", "--no-ff", "-m", "merge landed", "feature/landed")
        let landed = await watcher.newlyMerged(among: targets)
        #expect(landed.count == 1)
        #expect(landed.first?.threadId == "t-landed")
        #expect(landed.first?.baseBranch == "main")

        // A merge is announced once, not on every poll after it.
        #expect(await watcher.newlyMerged(among: targets).isEmpty)

        try repository.git("merge", "-q", "--no-ff", "-m", "merge open", "feature/open")
        #expect(await watcher.newlyMerged(among: targets).first?.branch == "feature/open")
    }

    /// The real-world case: the pull request is squash merged on GitHub, so the
    /// branch is never an ancestor of the base and local git can never tell.
    @Test func reportsASquashMergedPullRequest() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }

        try repository.git("checkout", "-q", "-b", "t3code/keybinds")
        try repository.commit(file: "b.txt", message: "work")
        try repository.git("checkout", "-q", "main")
        // A squash merge rewrites the commit, so the trunk moves without ever
        // containing the branch.
        try repository.commit(file: "b.txt", message: "squashed work (#23)")

        let launch = Date()
        let forge = StubForge(
            answer: .merged(
                MergeWatcher.MergedPullRequest(
                    baseBranch: "main",
                    mergedAt: launch.addingTimeInterval(30)
                )
            )
        )
        let watcher = MergeWatcher(forge: forge.asForge, startedAt: launch)
        let target = MergeWatcher.Target(
            threadId: "t",
            branch: "t3code/keybinds",
            repositoryRoot: repository.path
        )

        let found = await watcher.newlyMerged(among: [target])
        #expect(found.first?.branch == "t3code/keybinds")
        #expect(found.first?.baseBranch == "main")
        // Announced once, and the forge is not asked again about it.
        #expect(await watcher.newlyMerged(among: [target]).isEmpty)
        #expect(await forge.callCount == 1)
    }

    /// The thread auto-settles in T3 Code the moment it sees the merge, so the
    /// notch stops being handed the thread — the branch must stay watched anyway.
    @Test func keepsWatchingAfterTheThreadStopsBeingReported() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }

        let launch = Date()
        let forge = StubForge(answer: .notMerged)
        let clock = TestClock(launch)
        let watcher = MergeWatcher(
            forge: forge.asForge,
            startedAt: launch,
            clock: clock.closure
        )
        let target = MergeWatcher.Target(
            threadId: "t",
            branch: "t3code/keybinds",
            repositoryRoot: repository.path
        )

        #expect(await watcher.newlyMerged(among: [target]).isEmpty)

        // The thread is gone from the notch; the pull request merges afterwards,
        // a couple of minutes later.
        clock.advance(120)
        await forge.setAnswer(
            .merged(
                MergeWatcher.MergedPullRequest(
                    baseBranch: "main",
                    mergedAt: launch.addingTimeInterval(120)
                )
            )
        )
        let found = await watcher.newlyMerged(among: [])
        #expect(found.first?.branch == "t3code/keybinds")
    }

    @Test func ignoresPullRequestsMergedBeforeLaunchAndUnavailableForges() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }

        let launch = Date()
        let old = StubForge(
            answer: .merged(
                MergeWatcher.MergedPullRequest(
                    baseBranch: "main",
                    mergedAt: launch.addingTimeInterval(-3600)
                )
            )
        )
        let watcher = MergeWatcher(forge: old.asForge, startedAt: launch)
        let target = MergeWatcher.Target(
            threadId: "t",
            branch: "t3code/old",
            repositoryRoot: repository.path
        )
        #expect(await watcher.newlyMerged(among: [target]).isEmpty)

        // An unusable forge backs off rather than being asked on every poll.
        let broken = StubForge(answer: .unavailable)
        let brokenClock = TestClock(launch)
        let backingOff = MergeWatcher(
            forge: broken.asForge,
            startedAt: launch,
            clock: brokenClock.closure
        )
        for _ in 0..<4 {
            #expect(await backingOff.newlyMerged(among: [target]).isEmpty)
            brokenClock.advance(90)
        }
        #expect(await broken.callCount == 1)
    }

    @Test func parsesRealGhOutput() throws {
        // Captured from `gh pr list --head <branch> --state merged --limit 1
        // --json mergedAt,baseRefName`.
        let merged = MergeWatcher.parseMergedPullRequest(
            #"[{"baseRefName":"main","mergedAt":"2026-07-26T22:42:30Z"}]"#
        )
        #expect(merged?.baseBranch == "main")
        #expect(merged?.mergedAt == Date(timeIntervalSince1970: 1_785_105_750))

        #expect(MergeWatcher.parseMergedPullRequest("[]") == nil)
        #expect(MergeWatcher.parseMergedPullRequest("") == nil)
        #expect(MergeWatcher.parseMergedPullRequest("not json") == nil)
    }

    /// A worktree branch starts life pointing at the trunk's tip, which is
    /// technically "contained by main" while being the opposite of merged.
    @Test func aBranchWithNoCommitsOfItsOwnIsNotAMerge() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }

        try repository.git("branch", "feature/fresh", "main")

        let watcher = MergeWatcher(forge: .silent)
        let target = MergeWatcher.Target(
            threadId: "t",
            branch: "feature/fresh",
            repositoryRoot: repository.path
        )
        #expect(await watcher.newlyMerged(among: [target]).isEmpty)
        #expect(await watcher.newlyMerged(among: [target]).isEmpty)

        // Once it has a commit and that commit lands, it is a real merge.
        try repository.git("checkout", "-q", "feature/fresh")
        try repository.commit(file: "d.txt", message: "real work")
        try repository.git("checkout", "-q", "main")
        #expect(await watcher.newlyMerged(among: [target]).isEmpty)

        try repository.git("merge", "-q", "--no-ff", "-m", "land it", "feature/fresh")
        #expect(await watcher.newlyMerged(among: [target]).first?.branch == "feature/fresh")
    }

    /// A branch merged before the app started is history, not news.
    @Test func doesNotReportMergesThatPredateWatching() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }

        try repository.git("checkout", "-q", "-b", "feature/old")
        try repository.commit(file: "b.txt", message: "old work")
        try repository.git("checkout", "-q", "main")
        try repository.git("merge", "-q", "--no-ff", "-m", "old merge", "feature/old")

        let watcher = MergeWatcher(forge: .silent)
        let target = MergeWatcher.Target(
            threadId: "t",
            branch: "feature/old",
            repositoryRoot: repository.path
        )
        #expect(await watcher.newlyMerged(among: [target]).isEmpty)
        #expect(await watcher.newlyMerged(among: [target]).isEmpty)
    }

    @Test func staysQuietWithoutARepositoryOrBranch() async throws {
        let repository = try TestRepository()
        defer { repository.remove() }

        let watcher = MergeWatcher(forge: .silent)

        let missingRepository = MergeWatcher.Target(
            threadId: "t",
            branch: "main",
            repositoryRoot: repository.path + "-does-not-exist"
        )
        #expect(await watcher.newlyMerged(among: [missingRepository]).isEmpty)

        let missingBranch = MergeWatcher.Target(
            threadId: "t",
            branch: "feature/never-existed",
            repositoryRoot: repository.path
        )
        #expect(await watcher.newlyMerged(among: [missingBranch]).isEmpty)

        // The trunk is not "merged into itself", however many polls go by.
        let baseItself = MergeWatcher.Target(
            threadId: "t",
            branch: "main",
            repositoryRoot: repository.path
        )
        #expect(await watcher.newlyMerged(among: [baseItself]).isEmpty)
        #expect(await watcher.newlyMerged(among: [baseItself]).isEmpty)
    }
}

/// Stands in for the GitHub CLI: no network, and it counts how often it is asked.
private actor StubForge {
    private var answer: MergeWatcher.ForgeAnswer
    private(set) var callCount = 0

    init(answer: MergeWatcher.ForgeAnswer) {
        self.answer = answer
    }

    func setAnswer(_ answer: MergeWatcher.ForgeAnswer) {
        self.answer = answer
    }

    private func respond() -> MergeWatcher.ForgeAnswer {
        callCount += 1
        return answer
    }

    nonisolated var asForge: MergeWatcher.Forge {
        MergeWatcher.Forge { [self] _, _ in await respond() }
    }
}

extension MergeWatcher.Forge {
    /// Never merged, and never a network call.
    static let silent = MergeWatcher.Forge { _, _ in .notMerged }
}

/// Hand-wound clock, so throttles and backoffs are exercised without sleeping.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) {
        value = start
    }

    var closure: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value = value.addingTimeInterval(seconds)
    }
}

private enum TestRepositoryError: Error {
    case gitFailed(command: String, status: Int32, message: String)
}

/// Throwaway git repository with one commit on `main`.
private struct TestRepository {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("t3notch-merge-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
        try git("init", "-q", "-b", "main", ".")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
        try commit(file: "a.txt", message: "first")
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }

    func commit(file: String, message: String) throws {
        try "content of \(file)".write(
            toFile: path + "/" + file,
            atomically: true,
            encoding: .utf8
        )
        try git("add", "-A")
        try git("commit", "-q", "-m", message)
    }

    /// Throws on a non-zero exit: a silent setup failure here looks exactly like
    /// a MergeWatcher bug, which is a miserable way to spend an afternoon.
    func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + arguments
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        try process.run()
        let errorOutput = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestRepositoryError.gitFailed(
                command: arguments.joined(separator: " "),
                status: process.terminationStatus,
                message: String(decoding: errorOutput, as: UTF8.self)
            )
        }
    }
}
