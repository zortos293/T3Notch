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

    /// Try `t3` on PATH, then `npx -y t3@latest`.
    public static func mintToken() async throws -> String {
        // Apps opened from Finder inherit macOS's minimal launchd PATH rather than
        // the PATH configured by the user's shell. Resolve it once so Homebrew,
        // nvm, fnm, Volta and similar Node installations remain discoverable.
        let environment = commandEnvironment()
        if let token = try? await runTokenCommand(
            ["t3", "auth", "session", "issue", "--token-only"],
            environment: environment
        ) {
            return token
        }
        return try await runTokenCommand(
            ["npx", "-y", "t3@latest", "auth", "session", "issue", "--token-only"],
            environment: environment
        )
    }

    public static func verifyToken(
        token: String,
        endpoint: ServerEndpoint,
        session: URLSession = .shared
    ) async throws -> ShellSnapshot {
        let client = T3HTTPClient(endpoint: endpoint, token: token, session: session)
        return try await client.fetchShell()
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
