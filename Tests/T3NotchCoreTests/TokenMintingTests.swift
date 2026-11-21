@testable import T3NotchCore
import Testing

@Suite("TokenMinting")
struct TokenMintingTests {
    @Test func triesTheNextCLIWhenTheServerRejectsTheFirstToken() async throws {
        let shell = ShellSnapshot(snapshotSequence: 4, projects: [], threads: [], updatedAt: "")
        let result = try await TokenMinting.firstVerifiedToken(
            from: [["bundled"], ["path"], ["npx"]],
            mint: { $0[0] },
            verify: { token in
                if token == "bundled" { throw T3HTTPError.unauthorized }
                #expect(token == "path")
                return shell
            }
        )
        #expect(result.token == "path")
        #expect(result.shell == shell)
    }

    @Test
    func preservesTheLoginShellPathAndRemovesDuplicates() {
        let path = TokenMinting.mergedCommandSearchPath(
            loginShellPath: "/Users/example/.nvm/current/bin:/opt/homebrew/bin:/usr/bin",
            processPath: "/usr/bin:/bin:/opt/homebrew/bin",
            homeDirectory: "/Users/example"
        )
        let components = path.split(separator: ":").map(String.init)

        #expect(components.first == "/Users/example/.nvm/current/bin")
        #expect(components.contains("/Users/example/.volta/bin"))
        #expect(components.contains("/opt/homebrew/bin"))
        #expect(components.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(components.filter { $0 == "/usr/bin" }.count == 1)
    }

    @Test
    func suppliesNodeAndSystemFallbackLocations() {
        let path = TokenMinting.mergedCommandSearchPath(
            loginShellPath: nil,
            processPath: nil,
            homeDirectory: "/Users/example"
        )
        let components = path.split(separator: ":").map(String.init)

        #expect(components.contains("/Users/example/.local/bin"))
        #expect(components.contains("/opt/homebrew/bin"))
        #expect(components.contains("/usr/local/bin"))
        #expect(components.contains("/usr/bin"))
        #expect(components.contains("/bin"))
    }
}
