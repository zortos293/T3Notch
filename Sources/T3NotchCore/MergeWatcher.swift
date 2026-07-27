import Foundation

/// Watches whether thread branches have landed.
///
/// T3 Code knows this over its WebSocket RPC (`subscribeVcsStatus`), which this
/// app's HTTP polling transport does not speak, so the same two sources T3 Code
/// uses are consulted directly:
///
/// - the forge, via `gh pr list --head <branch> --state merged`, which is the
///   only thing that can see a squash merge — squashing rewrites the commits, so
///   a squash-merged branch is never an ancestor of the base branch, and no
///   amount of local git will say otherwise;
/// - the local repository, for branches that land as a real merge or a
///   fast-forward.
///
/// Branches stay watched after their thread disappears from the notch, because a
/// pull request is usually merged long after the agent stopped and T3 Code
/// auto-settles the thread the moment it sees the merge.
public actor MergeWatcher {
    public struct Target: Equatable, Sendable {
        public let threadId: String
        public let branch: String
        public let repositoryRoot: String

        public init(threadId: String, branch: String, repositoryRoot: String) {
            self.threadId = threadId
            self.branch = branch
            self.repositoryRoot = repositoryRoot
        }
    }

    public struct MergedBranch: Equatable, Sendable {
        public let threadId: String
        public let branch: String
        public let baseBranch: String
    }

    /// A merged pull request as reported by the forge.
    public struct MergedPullRequest: Equatable, Sendable {
        public let baseBranch: String
        public let mergedAt: Date

        public init(baseBranch: String, mergedAt: Date) {
            self.baseBranch = baseBranch
            self.mergedAt = mergedAt
        }
    }

    public enum ForgeAnswer: Equatable, Sendable {
        case merged(MergedPullRequest)
        case notMerged
        /// No `gh`, not signed in, not a forge repository, or offline.
        case unavailable
    }

    /// Indirection so tests can answer for the forge without a network.
    public struct Forge: Sendable {
        public let mergedPullRequest:
            @Sendable (_ branch: String, _ repositoryRoot: String) async -> ForgeAnswer

        public init(
            mergedPullRequest: @escaping @Sendable (String, String) async -> ForgeAnswer
        ) {
            self.mergedPullRequest = mergedPullRequest
        }
    }

    private struct Watch {
        var target: Target
        var firstSeen: Date
        /// Seen carrying commits the base branch did not have.
        var sawUnmergedCommits = false
        var lastForgeCheck: Date?
    }

    private var watched: [String: Watch] = [:]
    private var reported: Set<String> = []
    private var basesByRoot: [String: [String]] = [:]
    /// Set when `gh` is missing, unauthenticated, or offline, so a broken setup
    /// costs one process spawn a quarter-hour instead of one per poll.
    private var forgeBlockedUntil: Date?

    private let startedAt: Date
    private let forge: Forge
    private let clock: @Sendable () -> Date

    private let forgeInterval: TimeInterval = 60
    private let forgeBackoff: TimeInterval = 900
    private let watchLifetime: TimeInterval = 12 * 3600
    private let maxWatched = 40
    private static let trunkNames: Set<String> = ["main", "master", "trunk"]

    public init(
        forge: Forge = .gh,
        startedAt: Date = Date(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.forge = forge
        self.startedAt = startedAt
        self.clock = clock
    }

    /// Branches that have landed since the last call.
    ///
    /// Only merges that happen while this watcher is alive are reported: a branch
    /// merged beforehand is history, not news.
    public func newlyMerged(among targets: [Target]) async -> [MergedBranch] {
        register(targets)
        prune()

        var found: [MergedBranch] = []
        for key in watched.keys.sorted() {
            guard let base = await landedBase(for: key) else { continue }
            guard let watch = watched[key] else { continue }
            reported.insert(key)
            watched[key] = nil
            found.append(
                MergedBranch(
                    threadId: watch.target.threadId,
                    branch: watch.target.branch,
                    baseBranch: base
                )
            )
        }
        return found
    }

    private func register(_ targets: [Target]) {
        for target in targets {
            // A thread working directly on the trunk has nothing to land.
            guard !Self.trunkNames.contains(target.branch) else { continue }
            let key = "\(target.threadId):\(target.branch)"
            guard !reported.contains(key) else { continue }
            if watched[key] == nil {
                watched[key] = Watch(target: target, firstSeen: clock())
            } else {
                watched[key]?.target = target
            }
        }
    }

    /// Drops branches that have been outstanding long enough to be abandoned, so
    /// a long-lived notch is not polling a forge about last week's work.
    private func prune() {
        let cutoff = clock().addingTimeInterval(-watchLifetime)
        watched = watched.filter { $0.value.firstSeen > cutoff }
        guard watched.count > maxWatched else { return }
        let keep = watched
            .sorted { $0.value.firstSeen > $1.value.firstSeen }
            .prefix(maxWatched)
        watched = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    /// The base branch this one landed in, if it has.
    private func landedBase(for key: String) async -> String? {
        guard let watch = watched[key] else { return nil }
        let target = watch.target

        switch await inspect(target) {
        case let .containedBy(base):
            // Contained but never seen ahead means it either never had commits of
            // its own or it landed before this app was watching.
            if watch.sawUnmergedCommits {
                return base
            }
        case .ahead:
            watched[key]?.sawUnmergedCommits = true
        case .unknown:
            break
        }

        return await forgeLandedBase(for: key)
    }

    private func forgeLandedBase(for key: String) async -> String? {
        guard let watch = watched[key] else { return nil }
        let now = clock()
        if let blockedUntil = forgeBlockedUntil {
            guard now >= blockedUntil else { return nil }
            forgeBlockedUntil = nil
        }
        if let last = watch.lastForgeCheck, now.timeIntervalSince(last) < forgeInterval {
            return nil
        }
        watched[key]?.lastForgeCheck = now

        let answer = await forge.mergedPullRequest(
            watch.target.branch,
            watch.target.repositoryRoot
        )
        switch answer {
        case .notMerged:
            return nil
        case .unavailable:
            forgeBlockedUntil = now.addingTimeInterval(forgeBackoff)
            return nil
        case let .merged(merged):
            // A pull request merged before launch is not news.
            guard merged.mergedAt > startedAt else {
                reported.insert(key)
                watched[key] = nil
                return nil
            }
            return merged.baseBranch
        }
    }

    private enum BranchState {
        /// Carries commits the base branch does not have.
        case ahead
        /// Every commit is already in this base branch.
        case containedBy(String)
        /// No repository, no branch, or no base branch to compare against.
        case unknown
    }

    private func inspect(_ target: Target) async -> BranchState {
        let root = target.repositoryRoot
        // A branch deleted after merging leaves nothing to compare locally; the
        // forge is the fallback for that case.
        guard await gitSucceeds(["-C", root, "rev-parse", "--verify", "--quiet", target.branch])
        else { return .unknown }

        var isAheadOfSomeBase = false
        for base in await baseBranches(for: root) {
            // A trunk is not merged into itself, and `main` has not "landed"
            // merely because `origin/main` contains it.
            guard !isSameBranch(target.branch, as: base) else { continue }

            let result = await git(
                ["-C", root, "rev-list", "--count", "\(base)..\(target.branch)"]
            )
            guard result.status == 0,
                let ahead = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }

            // Landing locally and landing on the forge both count, so every base
            // is checked before concluding the branch is still outstanding.
            if ahead == 0 {
                return .containedBy(base)
            }
            isAheadOfSomeBase = true
        }

        return isAheadOfSomeBase ? .ahead : .unknown
    }

    /// `main` and `origin/main` are the same line of work here; `feature/main` is
    /// not, so only the remote prefix is stripped.
    private func isSameBranch(_ branch: String, as base: String) -> Bool {
        let remotePrefix = "origin/"
        let baseWithoutRemote =
            base.hasPrefix(remotePrefix) ? String(base.dropFirst(remotePrefix.count)) : base
        return branch == base || branch == baseWithoutRemote
    }

    /// Local trunk plus the remote's default branch. Both are checked because a
    /// merge can land either side, and the notch never fetches.
    private func baseBranches(for root: String) async -> [String] {
        if let cached = basesByRoot[root] { return cached }

        var bases: [String] = []
        for candidate in ["main", "master", "trunk"] {
            if await gitSucceeds(["-C", root, "rev-parse", "--verify", "--quiet", candidate]) {
                bases.append(candidate)
                break
            }
        }
        let remote = await git(
            ["-C", root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"]
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remote.isEmpty {
            bases.append(remote)
        }
        basesByRoot[root] = bases
        return bases
    }

    private func gitSucceeds(_ arguments: [String]) async -> Bool {
        await git(arguments).status == 0
    }

    private func git(_ arguments: [String]) async -> (status: Int32, output: String) {
        guard let executable = Self.locate("git") else { return (-1, "") }
        return await Self.run(executable, arguments, in: nil)
    }

    static func locate(_ tool: String) -> String? {
        let candidates = ["/usr/bin/", "/opt/homebrew/bin/", "/usr/local/bin/"]
            .map { $0 + tool }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        in directory: String?,
        timeout: TimeInterval = 15
    ) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let directory {
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
            }
            var environment = ProcessInfo.processInfo.environment
            // Never block on credentials, never take the repo's index lock, and
            // never let a CLI decide to be chatty.
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            environment["GH_NO_UPDATE_NOTIFIER"] = "1"
            environment["GH_PROMPT_DISABLED"] = "1"
            environment["NO_COLOR"] = "1"
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            // Exactly one of these resumes: a process that never launched has no
            // termination to handle.
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self))
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, ""))
                return
            }

            // A hung network call must not keep a process, or this task, alive.
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}

extension MergeWatcher.Forge {
    /// Never asks anything, for local-merge-only watching.
    public static let disabled = MergeWatcher.Forge { _, _ in .notMerged }

    /// Asks the GitHub CLI, which is the same tool T3 Code drives for pull
    /// request state.
    public static let gh = MergeWatcher.Forge { branch, root in
        guard let executable = MergeWatcher.locate("gh") else { return .unavailable }
        let result = await MergeWatcher.run(
            executable,
            [
                "pr", "list",
                "--head", branch,
                "--state", "merged",
                "--limit", "1",
                "--json", "mergedAt,baseRefName",
            ],
            in: root
        )
        guard result.status == 0 else { return .unavailable }
        guard let merged = MergeWatcher.parseMergedPullRequest(result.output) else {
            return .notMerged
        }
        return .merged(merged)
    }
}

extension MergeWatcher {
    /// Parses `gh pr list --json mergedAt,baseRefName` output.
    static func parseMergedPullRequest(_ json: String) -> MergedPullRequest? {
        guard let data = json.data(using: .utf8),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let first = entries.first,
            let mergedAt = first["mergedAt"] as? String,
            let baseBranch = first["baseRefName"] as? String,
            let date = try? Date(mergedAt, strategy: .iso8601)
        else { return nil }
        return MergedPullRequest(baseBranch: baseBranch, mergedAt: date)
    }
}
