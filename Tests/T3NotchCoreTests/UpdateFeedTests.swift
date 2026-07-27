import Foundation
import Testing

@testable import T3NotchCore

@Suite("AppVersion")
struct AppVersionTests {
    @Test func readsTheShapesReleaseTagsActuallyUse() {
        #expect(AppVersion("1.2.3") == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(AppVersion("v1.2.3") == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(AppVersion("1.2") == AppVersion(major: 1, minor: 2, patch: 0))
        // Build metadata takes no part in precedence, so it is dropped.
        #expect(AppVersion("1.2.3+build.9") == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(AppVersion("1.2.3-beta.1")?.prerelease == ["beta", "1"])
        #expect(AppVersion("1.2.3-beta.1")?.description == "1.2.3-beta.1")
    }

    @Test func refusesThingsThatAreNotVersions() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("nightly") == nil)
        #expect(AppVersion("1.2.3.4") == nil)
        #expect(AppVersion("1.-2.3") == nil)
        #expect(AppVersion("1.2.3-") == nil)
    }

    @Test func ordersReleasesTheWaySemverSays() throws {
        func version(_ text: String) throws -> AppVersion {
            try #require(AppVersion(text))
        }

        #expect(try version("1.0.0") < version("1.0.1"))
        #expect(try version("1.0.9") < version("1.1.0"))
        #expect(try version("1.9.0") < version("2.0.0"))
        // A pre-release comes before the release it leads up to.
        #expect(try version("1.1.0-beta.1") < version("1.1.0"))
        #expect(try version("1.1.0-beta.2") < version("1.1.0-beta.10"))
        #expect(try version("1.1.0-alpha") < version("1.1.0-beta"))
        #expect(try version("1.1.0-beta") < version("1.1.0-beta.1"))
        #expect(try version("1.0.0") == version("v1.0.0"))
    }
}

@Suite("GitHubUpdateFeed")
struct GitHubUpdateFeedTests {
    /// Trimmed to the fields the feed reads, in GitHub's own shape.
    private func payload(_ releases: [String]) -> Data {
        Data("[\(releases.joined(separator: ","))]".utf8)
    }

    private func release(
        tag: String,
        prerelease: Bool = false,
        draft: Bool = false,
        assets: [String] = ["T3Notch-arm64.zip"]
    ) -> String {
        let assetJSON = assets.map {
            """
            {"name":"\($0)",
             "browser_download_url":"https://example.test/\($0)",
             "size":1024}
            """
        }
        return """
            {"tag_name":"\(tag)",
             "name":"T3Notch \(tag)",
             "body":"notes",
             "draft":\(draft),
             "prerelease":\(prerelease),
             "published_at":"2026-07-27T10:58:17Z",
             "html_url":"https://github.com/zortos293/T3Notch/releases/tag/\(tag)",
             "assets":[\(assetJSON.joined(separator: ","))]}
            """
    }

    @Test func picksTheHighestVersionRatherThanTheFirstListed() throws {
        let data = payload([release(tag: "v1.0.0"), release(tag: "v1.2.0"), release(tag: "v1.1.0")])
        let newest = try GitHubUpdateFeed.newestRelease(
            in: data,
            channel: .stable,
            architecture: "arm64"
        )
        #expect(newest?.tag == "v1.2.0")
        #expect(newest?.asset.url.absoluteString == "https://example.test/T3Notch-arm64.zip")
        #expect(newest?.name == "T3Notch v1.2.0")
    }

    @Test func holdsBackPrereleasesUnlessAskedForThem() throws {
        let data = payload([
            release(tag: "v1.0.0"),
            release(tag: "v1.1.0-beta.1", prerelease: true),
        ])

        let stable = try GitHubUpdateFeed.newestRelease(in: data, channel: .stable)
        #expect(stable?.tag == "v1.0.0")

        let nightly = try GitHubUpdateFeed.newestRelease(in: data, channel: .prerelease)
        #expect(nightly?.tag == "v1.1.0-beta.1")
        #expect(nightly?.isPrerelease == true)
    }

    @Test func treatsAPrereleaseTagAsOneEvenWhenGitHubDoesNot() throws {
        let data = payload([release(tag: "v1.1.0-rc.1", prerelease: false)])
        #expect(try GitHubUpdateFeed.newestRelease(in: data, channel: .stable) == nil)
        #expect(try GitHubUpdateFeed.newestRelease(in: data, channel: .prerelease)?.tag
            == "v1.1.0-rc.1")
    }

    @Test func ignoresDraftsAndReleasesWithNothingToDownload() throws {
        let data = payload([
            release(tag: "v2.0.0", draft: true),
            release(tag: "v1.9.0", assets: []),
            release(tag: "v1.8.0", assets: ["T3Notch-x86_64.zip"]),
            release(tag: "v1.7.0"),
        ])
        #expect(try GitHubUpdateFeed.newestRelease(in: data, channel: .stable)?.tag == "v1.7.0")
    }

    @Test func takesASingleUnlabelledZipAsUniversal() throws {
        let data = payload([release(tag: "v1.3.0", assets: ["T3Notch.zip"])])
        let newest = try GitHubUpdateFeed.newestRelease(in: data, channel: .stable)
        #expect(newest?.asset.name == "T3Notch.zip")
    }

    @Test func returnsNothingForARepositoryWithNoReleases() throws {
        #expect(try GitHubUpdateFeed.newestRelease(in: Data("[]".utf8), channel: .prerelease) == nil)
    }
}
