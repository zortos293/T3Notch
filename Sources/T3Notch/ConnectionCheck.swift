import Foundation
import T3NotchCore

/// Runs the things that have to work for each watched source, and reports what
/// each one actually did. Every step performs a real request or a real read;
/// nothing here is a guess about state held elsewhere in the app.
///
/// Sources are independent: T3 Code being down says nothing about the local
/// Claude Code and Codex sessions, so a failure only skips the rest of its own
/// section and the run passes as long as one source came back usable.
@MainActor
@Observable
final class ConnectionCheck {
    enum Outcome: Equatable {
        case waiting
        case running
        case passed(String)
        /// Worth saying, but not a reason to call the source unusable.
        case warned(String)
        case failed(String)
    }

    struct Step: Identifiable, Equatable {
        let id: String
        /// Which source's section this belongs to, so one failure cannot skip
        /// steps that have nothing to do with it.
        let source: AgentSource
        let title: String
        var outcome: Outcome = .waiting
    }

    private(set) var steps: [Step] = []
    private(set) var isRunning = false
    /// Set when at least one source came back usable, for a one-line summary.
    private(set) var summary: String?

    /// Sources that finished their section without a failure.
    private var usableSources: Set<AgentSource> = []

    func run(sources values: SettingsStore.Values) async {
        guard !isRunning else { return }
        isRunning = true
        steps = Self.freshSteps(for: values)
        summary = nil
        usableSources = []
        defer { isRunning = false }

        var parts: [String] = []
        if values.watchT3, let part = await runT3Section() {
            usableSources.insert(.t3)
            parts.append(part)
        }
        if values.watchClaude, let part = runClaudeSection() {
            usableSources.insert(.claude)
            parts.append(part)
        }
        if values.watchCodex, let part = runCodexSection() {
            usableSources.insert(.codex)
            parts.append(part)
        }

        guard !usableSources.isEmpty else { return }
        summary = parts.joined(separator: " · ")
    }

    // MARK: - Sections

    /// Returns the section's summary fragment, or nil if T3 Code is unusable.
    private func runT3Section() async -> String? {
        // 1. Discovery.
        set("server", .running)
        let endpoint = await ServerDiscovery.resolveEndpoint()
        set("server", .passed("\(endpoint.host):\(endpoint.port)"))

        // 2. Reachability, which is what tells a stopped server from a bad token.
        set("reach", .running)
        guard await ServerDiscovery.isReachable(endpoint) else {
            set(
                "reach",
                .failed("Nothing answered on \(endpoint.host):\(endpoint.port). Is T3 Code running?")
            )
            failRemaining(after: "reach")
            return nil
        }
        var environmentLabel: String?
        do {
            let environment = try await T3HTTPClient(endpoint: endpoint, token: "")
                .fetchEnvironment()
            environmentLabel = environment.label
            set("reach", .passed(environment.label ?? "reachable"))
        } catch {
            // Reachable but unreadable is still progress worth distinguishing.
            set("reach", .passed("reachable, environment details unavailable"))
        }

        // 3. Token: whatever is in the Keychain, else mint a fresh one.
        set("token", .running)
        var token = KeychainStore.loadToken()
        if token == nil {
            do {
                let minted = try await TokenMinting.mintToken()
                try KeychainStore.saveToken(minted)
                token = minted
                set("token", .passed("minted a new token and saved it to the Keychain"))
            } catch {
                set(
                    "token",
                    .failed(
                        "Could not mint one: \(error.localizedDescription)\n"
                            + "Run: t3 auth session issue --token-only"
                    )
                )
                failRemaining(after: "token")
                return nil
            }
        }
        guard let token else {
            set("token", .failed("No token available"))
            failRemaining(after: "token")
            return nil
        }

        // 4. The token is only proven by a call that needs it.
        set("read", .running)
        do {
            let shell = try await TokenMinting.verifyToken(token: token, endpoint: endpoint)
            if case .running = outcome(of: "token") {
                set("token", .passed("saved token accepted"))
            }
            let projects = shell.projects.count
            let threads = shell.threads.count
            set(
                "read",
                .passed(
                    "\(projects) \(projects == 1 ? "project" : "projects"), "
                        + "\(threads) \(threads == 1 ? "thread" : "threads")"
                )
            )
            return [environmentLabel, "\(threads) T3 threads visible"]
                .compactMap { $0 }
                .joined(separator: " · ")
        } catch {
            set("token", .failed("Token was rejected"))
            set(
                "read",
                .failed(
                    "\(error.localizedDescription)\nRun: t3 auth session issue --token-only"
                )
            )
            return nil
        }
    }

    /// Missing hooks are a warning: transcripts still drive the cards, only the
    /// permission prompts stay in the terminal.
    private func runClaudeSection() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")

        set("claude-dirs", .running)
        let projects = home.appendingPathComponent("projects")
        guard FileManager.default.isReadableFile(atPath: projects.path) else {
            set(
                "claude-dirs",
                .failed("No ~/.claude/projects. Has Claude Code run on this Mac?")
            )
            failRemaining(after: "claude-dirs")
            return nil
        }
        set("claude-dirs", .passed(projects.path))

        set("claude-sessions", .running)
        let live = liveClaudeSessions(home: home)
        set(
            "claude-sessions",
            .passed(
                live == 0
                    ? "none right now — start one and it appears in the notch"
                    : "\(live) live \(live == 1 ? "session" : "sessions")"
            )
        )

        set("claude-hooks", .running)
        switch ClaudeHookInstaller().status() {
        case let .installed(port):
            set("claude-hooks", .passed("installed on port \(port)"))
        case .notInstalled:
            set(
                "claude-hooks",
                .warned("not installed — approvals stay in the terminal")
            )
        case let .partial(missing):
            set(
                "claude-hooks",
                .warned(
                    missing.isEmpty
                        ? "installed on more than one port — install them again"
                        : "missing \(missing.joined(separator: ", ")) — install them again"
                )
            )
        case let .unreadable(reason):
            set("claude-hooks", .warned("could not read ~/.claude/settings.json: \(reason)"))
        }

        return live == 0
            ? "Claude Code ready"
            : "\(live) Claude Code \(live == 1 ? "session" : "sessions")"
    }

    private func liveClaudeSessions(home: URL) -> Int {
        let directory = home.appendingPathComponent("sessions")
        // Listed by path, not by URL: a symlinked home makes the URL variant
        // come back empty.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let decoder = JSONDecoder()
        return names.filter { $0.hasSuffix(".json") }.reduce(into: 0) { count, name in
            guard let data = try? Data(
                contentsOf: directory.appendingPathComponent(name)
            ),
                let entry = try? decoder.decode(ClaudeSessionEntry.self, from: data),
                entry.isInteractive,
                ClaudeSessionRegistry.processIsAlive(entry.pid)
            else { return }
            count += 1
        }
    }

    private func runCodexSection() -> String? {
        set("codex-dirs", .running)
        let scanner = CodexRolloutScanner(
            codexHome: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex")
        )
        guard FileManager.default.isReadableFile(atPath: scanner.sessionsDirectory.path) else {
            set(
                "codex-dirs",
                .failed("No ~/.codex/sessions. Has the Codex CLI run on this Mac?")
            )
            return nil
        }
        let rollouts = scanner.scan()
        guard let newest = rollouts.map(\.modifiedAt).max() else {
            set("codex-dirs", .passed("no sessions today — run one and it appears"))
            return "Codex ready"
        }
        let live = rollouts.filter(\.isLive).count
        set(
            "codex-dirs",
            .passed("newest rollout \(Self.age(of: newest)), \(live) live")
        )
        return live == 0 ? "Codex ready" : "\(live) Codex \(live == 1 ? "session" : "sessions")"
    }

    private static func age(of date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    // MARK: - Steps

    private static func freshSteps(for values: SettingsStore.Values) -> [Step] {
        var steps: [Step] = []
        if values.watchT3 {
            steps += [
                Step(id: "server", source: .t3, title: "Find the T3 Code server"),
                Step(id: "reach", source: .t3, title: "Reach its environment endpoint"),
                Step(id: "token", source: .t3, title: "Authorise with a session token"),
                Step(id: "read", source: .t3, title: "Read projects and threads"),
            ]
        }
        if values.watchClaude {
            steps += [
                Step(id: "claude-dirs", source: .claude, title: "Find Claude Code's files"),
                Step(id: "claude-sessions", source: .claude, title: "Look for live Claude sessions"),
                Step(id: "claude-hooks", source: .claude, title: "Check the Claude Code hooks"),
            ]
        }
        if values.watchCodex {
            steps += [
                Step(id: "codex-dirs", source: .codex, title: "Find Codex's session rollouts"),
            ]
        }
        return steps
    }

    /// The first real failure, short enough for the notch, and only when nothing
    /// else came back usable. Steps that were skipped after it are not the story.
    var failure: String? {
        guard !isRunning, usableSources.isEmpty else { return nil }
        for step in steps {
            if case let .failed(message) = step.outcome, message != "Skipped" {
                return step.title
            }
        }
        return nil
    }

    private func outcome(of id: String) -> Outcome {
        steps.first { $0.id == id }?.outcome ?? .waiting
    }

    private func set(_ id: String, _ outcome: Outcome) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].outcome = outcome
    }

    /// Steps after a failure never ran, and saying so beats leaving them
    /// spinning. Only the failed source's own steps are skipped.
    private func failRemaining(after id: String) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let source = steps[index].source
        for later in steps.indices where later > index && steps[later].source == source {
            steps[later].outcome = .failed("Skipped")
        }
    }
}
