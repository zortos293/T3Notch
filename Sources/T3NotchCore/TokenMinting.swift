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
        if let token = try? await runTokenCommand(["t3", "auth", "session", "issue", "--token-only"]) {
            return token
        }
        return try await runTokenCommand([
            "npx", "-y", "t3@latest", "auth", "session", "issue", "--token-only",
        ])
    }

    public static func verifyToken(
        token: String,
        endpoint: ServerEndpoint,
        session: URLSession = .shared
    ) async throws -> ShellSnapshot {
        let client = T3HTTPClient(endpoint: endpoint, token: token, session: session)
        return try await client.fetchShell()
    }

    private static func runTokenCommand(_ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = arguments
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
}
