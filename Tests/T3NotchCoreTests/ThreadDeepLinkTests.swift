import Foundation
import Testing
@testable import T3NotchCore

@Suite("ThreadDeepLink")
struct ThreadDeepLinkTests {
    /// Thread ids as the redacted live shell has them: `import:<provider>:<uuid>`.
    private let environmentId = "3f0c1a2e-8d4b-4e7a-9c1f-2b6d5e8a7c90"
    private let threadId = "import:claudeAgent:53216d79-4001-46c4-b1fe-618580719506"

    @Test func desktopLinkEncodesColonsInTheThreadId() {
        let url = ThreadDeepLink.desktopURL(environmentId: environmentId, threadId: threadId)

        #expect(url?.absoluteString == "t3code://threads/\(environmentId)/import%3AclaudeAgent%3A53216d79-4001-46c4-b1fe-618580719506")
    }

    @Test func webPathMatchesTheDesktopPathComponents() {
        let path = ThreadDeepLink.webPath(environmentId: environmentId, threadId: threadId)

        #expect(path == "/threads/\(environmentId)/import%3AclaudeAgent%3A53216d79-4001-46c4-b1fe-618580719506")
    }

    @Test func percentSignsAreEncodedBeforeColons() {
        let thread = "100%:done"

        #expect(ThreadDeepLink.encodeURIComponent(thread) == "100%25%3Adone")
        #expect(ThreadDeepLink.webPath(environmentId: "env", threadId: thread) == "/threads/env/100%25%3Adone")
    }

    @Test func reservedCharactersAreEncodedLikeEncodeURIComponent() {
        #expect(ThreadDeepLink.encodeURIComponent("a/b?c#d&e=f+g h") == "a%2Fb%3Fc%23d%26e%3Df%2Bg%20h")
    }

    @Test func nonAsciiIsEncodedAsUTF8() {
        #expect(ThreadDeepLink.encodeURIComponent("café") == "caf%C3%A9")
    }

    @Test func unreservedCharactersPassThrough() {
        #expect(ThreadDeepLink.encodeURIComponent("AZaz09-_.!~*'()") == "AZaz09-_.!~*'()")
    }

    @Test func devBuildUsesTheDevScheme() {
        let url = ThreadDeepLink.desktopURL(
            scheme: ThreadDeepLink.developmentScheme,
            environmentId: environmentId,
            threadId: threadId
        )

        #expect(url?.scheme == "t3code-dev")
        #expect(url?.host == "threads")
    }

    @Test func decodingThePathGivesBackTheOriginalIds() throws {
        let thread = "import:claudeAgent:100%:x/y?#"
        let url = try #require(ThreadDeepLink.desktopURL(environmentId: environmentId, threadId: thread))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let parts = components.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding }

        #expect(parts == [environmentId, thread])
    }

    @Test func webPathDecodesBackToTheOriginalIdsWhenResolved() throws {
        let thread = "provider-thread:provider:codex:native%thread"
        let base = try #require(URL(string: "https://app.example.test/"))
        let url = try #require(URL(
            string: ThreadDeepLink.webPath(environmentId: environmentId, threadId: thread),
            relativeTo: base
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: true))
        let parts = components.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding }

        #expect(url.host == "app.example.test")
        #expect(parts == ["threads", environmentId, thread])
    }
}
