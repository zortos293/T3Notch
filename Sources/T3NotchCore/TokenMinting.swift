import Foundation

public enum TokenMinting {
    public enum Error: Swift.Error, LocalizedError {
        case commandFailed(String)
        case emptyToken

        public var errorDescription: String? {
            switch self {
            case let .commandFailed(message):
                return message
            case .emptyToken:
                return "Token command returned empty output"
            }
        }
    }

    private static let issueArguments = [
        "auth", "session", "issue", "--token-only", "--scope", "orchestration:read",
        "--scope", "orchestration:operate", "--label", "T3Notch",
    ]

    public static let manualCommand = "t3 " + issueArguments.joined(separator: " ")

    public static func loadOrMintToken(
        endpoint: ServerEndpoint
    ) async throws -> (token: String, shell: ShellSnapshot, reused: Bool) {
        if let saved = KeychainStore.loadToken() {
            do {
                return (saved, try await verifyToken(token: saved, endpoint: endpoint), true)
            } catch T3HTTPError.unauthorized {
                // The stored token may belong to another installation of T3 Code.
            }
        }

        let environment = commandEnvironment()
        let bundled = environment["HOME"].map { [["\($0)/.t3/bin/t3"]] } ?? []
        let candidates = bundled + [["t3"], ["npx", "-y", "t3@latest"]]
        let verified = try await firstVerifiedToken(
            from: candidates,
            mint: { try await runTokenCommand($0 + issueArguments, environment: environment) },
            verify: { try await verifyToken(token: $0, endpoint: endpoint) }
        )
        try KeychainStore.saveToken(verified.token)
        return (verified.token, verified.shell, false)
    }

    static func firstVerifiedToken(
        from candidates: [[String]],
        mint: ([String]) async throws -> String,
        verify: (String) async throws -> ShellSnapshot
    ) async throws -> (token: String, shell: ShellSnapshot) {
        var lastError: Swift.Error = Error.emptyToken
        for candidate in candidates {
            try Task.checkCancellation()
            let token: String
            do {
                token = try await mint(candidate)
            } catch {
                lastError = error
                continue
            }
            do {
                return (token, try await verify(token))
            } catch T3HTTPError.unauthorized {
                lastError = T3HTTPError.unauthorized
            }
        }
        throw lastError
    }

    public static func verifyToken(
        token: String,
        endpoint: ServerEndpoint,
        session: URLSession = .shared
    ) async throws -> ShellSnapshot {
        struct SessionState: Decodable {
            let authenticated: Bool?
            let scopes: [String]?
        }
        let client = T3HTTPClient(endpoint: endpoint, token: token, session: session)
        let shell = try await client.fetchShell()
        do {
            let state: SessionState = try await client.get(path: "/api/auth/session")
            guard state.authenticated != false,
                  state.scopes?.contains("orchestration:operate") != false
            else { throw T3HTTPError.unauthorized }
        } catch T3HTTPError.httpStatus(404, _) {
            // Older servers do not expose session scopes.
        }
        return shell
    }

    private static func runTokenCommand(
        _ arguments: [String],
        environment: [String: String]
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = arguments
                    process.environment = environment
                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr
                    try process.run()
                    process.waitUntilExit()
                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let out = String(data: outData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let err = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard process.terminationStatus == 0 else {
                        continuation.resume(
                            throwing: Error.commandFailed(err.isEmpty ? out : err)
                        )
                        return
                    }
                    // Token-only output should be a single line.
                    let token = out.split(whereSeparator: \.isNewline)
                        .map(String.init)
                        .first(where: { !$0.isEmpty && !$0.hasPrefix("[") })
                        ?? out
                    guard !token.isEmpty else {
                        continuation.resume(throwing: Error.emptyToken)
                        return
                    }
                    continuation.resume(returning: token)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func commandEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let shellPath = loginShellSearchPath(environment: environment)
        environment["PATH"] = mergedCommandSearchPath(
            loginShellPath: shellPath,
            processPath: environment["PATH"],
            homeDirectory: environment["HOME"]
        )
        return environment
    }

    /// Ask the user's interactive login shell for PATH. `-i` matters for Node
    /// managers commonly initialized from .zshrc; `-l` also loads .zprofile.
    private static func loginShellSearchPath(
        environment: [String: String]
    ) -> String? {
        let requestedShell = environment["SHELL"] ?? "/bin/zsh"
        let shell = FileManager.default.isExecutableFile(atPath: requestedShell)
            ? requestedShell
            : "/bin/zsh"
        let marker = "__T3NOTCH_PATH__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "printf '\\n\(marker)%s\\n' \"$PATH\""]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return output.split(whereSeparator: \.isNewline)
            .reversed()
            .first(where: { $0.hasPrefix(marker) })
            .map { String($0.dropFirst(marker.count)) }
    }

    static func mergedCommandSearchPath(
        loginShellPath: String?,
        processPath: String?,
        homeDirectory: String?
    ) -> String {
        var candidates: [String] = []
        candidates.append(contentsOf: pathComponents(loginShellPath))
        if let homeDirectory, !homeDirectory.isEmpty {
            candidates.append(contentsOf: [
                "\(homeDirectory)/.local/bin",
                "\(homeDirectory)/.volta/bin",
                "\(homeDirectory)/.asdf/shims",
                "\(homeDirectory)/.bun/bin",
                "\(homeDirectory)/.npm-global/bin",
            ])
        }
        candidates.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
        candidates.append(contentsOf: pathComponents(processPath))
        candidates.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])

        var seen: Set<String> = []
        return candidates
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private static func pathComponents(_ path: String?) -> [String] {
        path?.split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []
    }
}
