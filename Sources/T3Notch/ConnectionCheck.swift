import Foundation
import T3NotchCore

/// Runs the four things that have to work, and reports what each one actually
/// did. Every step performs a real request; nothing here is a guess about state
/// held elsewhere in the app.
@MainActor
@Observable
final class ConnectionCheck {
    enum Outcome: Equatable {
        case waiting
        case running
        case passed(String)
        case failed(String)
    }

    struct Step: Identifiable, Equatable {
        let id: String
        let title: String
        var outcome: Outcome = .waiting
    }

    private(set) var steps: [Step] = ConnectionCheck.freshSteps
    private(set) var isRunning = false
    /// Set when the whole run succeeded, for a one-line summary.
    private(set) var summary: String?

    private static var freshSteps: [Step] {
        [
            Step(id: "server", title: "Find the T3 Code server"),
            Step(id: "reach", title: "Reach its environment endpoint"),
            Step(id: "token", title: "Authorise with a session token"),
            Step(id: "read", title: "Read projects and threads"),
        ]
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        steps = Self.freshSteps
        summary = nil
        defer { isRunning = false }

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
            return
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
                return
            }
        }
        guard let token else {
            set("token", .failed("No token available"))
            failRemaining(after: "token")
            return
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
            summary = [environmentLabel, "\(threads) threads visible"]
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
        }
    }

    /// The first real failure, short enough for the notch. Steps that were skipped
    /// after it are not the story.
    var failure: String? {
        guard !isRunning else { return nil }
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

    /// Steps after a failure never ran, and saying so beats leaving them spinning.
    private func failRemaining(after id: String) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        for later in steps.indices where later > index {
            steps[later].outcome = .failed("Skipped")
        }
    }
}
