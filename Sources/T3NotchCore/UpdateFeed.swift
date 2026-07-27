import Foundation

/// A version string, ordered the way semver says to order one.
///
/// Release tags are the only thing standing between a user and an unwanted
/// downgrade, so the comparison follows the spec rather than a string compare:
/// build metadata is ignored, and a pre-release sorts *before* the release it
/// leads up to (`1.2.0-beta.1` < `1.2.0`).
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Accepts `1`, `1.2`, `1.2.3`, `v1.2.3`, `1.2.3-beta.1`, `1.2.3+build.7`.
    public init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.first == "v" || body.first == "V" { body.removeFirst() }
        // Build metadata takes no part in precedence.
        if let plus = body.firstIndex(of: "+") { body = String(body[body.startIndex..<plus]) }
        guard !body.isEmpty else { return nil }

        let halves = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = halves[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(core.count) else { return nil }

        var numbers = [0, 0, 0]
        for (index, part) in core.enumerated() {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers[index] = value
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]

        if halves.count == 2 {
            let identifiers = halves[1].split(separator: ".").map(String.init)
            guard !identifiers.isEmpty else { return nil }
            prerelease = identifiers
        } else {
            prerelease = []
        }
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (left?, right?): return left < right
            // Numeric identifiers always rank below alphanumeric ones.
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// Which releases the app is willing to move to.
public enum UpdateChannel: String, Sendable, CaseIterable, Codable {
    /// Published, non-pre-release builds only.
    case stable
    /// Also takes GitHub pre-releases, the way T3 Code's nightly channel does.
    case prerelease

    public var allowsPrerelease: Bool { self == .prerelease }
}

/// The zip a release offers for this machine.
public struct UpdateAsset: Sendable, Equatable {
    public let name: String
    public let url: URL
    public let size: Int

    public init(name: String, url: URL, size: Int) {
        self.name = name
        self.url = url
        self.size = size
    }
}

public struct UpdateRelease: Sendable, Equatable, Identifiable {
    public let version: AppVersion
    public let tag: String
    public let name: String
    public let notes: String
    public let isPrerelease: Bool
    public let publishedAt: Date?
    public let pageURL: URL
    public let asset: UpdateAsset

    public var id: String { tag }

    public init(
        version: AppVersion,
        tag: String,
        name: String,
        notes: String,
        isPrerelease: Bool,
        publishedAt: Date?,
        pageURL: URL,
        asset: UpdateAsset
    ) {
        self.version = version
        self.tag = tag
        self.name = name
        self.notes = notes
        self.isPrerelease = isPrerelease
        self.publishedAt = publishedAt
        self.pageURL = pageURL
        self.asset = asset
    }
}

public enum UpdateFeedError: Error, LocalizedError, Sendable {
    case httpStatus(Int)
    case rateLimited(until: Date?)
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case let .httpStatus(code):
            return "GitHub answered HTTP \(code)"
        case let .rateLimited(until):
            guard let until else { return "GitHub rate limit reached" }
            let minutes = max(1, Int(until.timeIntervalSinceNow / 60))
            return "GitHub rate limit reached, try again in \(minutes) min"
        case let .decoding(message):
            return "Could not read the release list: \(message)"
        case let .transport(message):
            return message
        }
    }
}

/// Reads releases straight off the GitHub API.
///
/// electron-updater, which T3 Code uses, publishes a `latest-mac.yml` manifest
/// next to the build. A single-asset app does not need one: the releases
/// endpoint already carries the version, the notes, and the download URL, and it
/// is the same list a person would look at.
public struct GitHubUpdateFeed: Sendable {
    public let owner: String
    public let repository: String
    private let session: URLSession

    public init(owner: String, repository: String, session: URLSession = .shared) {
        self.owner = owner
        self.repository = repository
        self.session = session
    }

    /// The one T3Notch ships against.
    public static let t3notch = GitHubUpdateFeed(owner: "zortos293", repository: "T3Notch")

    public var releasesPageURL: URL {
        URL(string: "https://github.com/\(owner)/\(repository)/releases")!
    }

    /// Newest release on `channel` that carries a zip this machine can run, or
    /// `nil` when the repository has no usable release at all.
    public func newestRelease(
        channel: UpdateChannel,
        architecture: String = GitHubUpdateFeed.machineArchitecture
    ) async throws -> UpdateRelease? {
        var components = URLComponents(
            string: "https://api.github.com/repos/\(owner)/\(repository)/releases"
        )!
        components.queryItems = [URLQueryItem(name: "per_page", value: "20")]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("T3Notch", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateFeedError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateFeedError.transport("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Unauthenticated callers get 60 requests an hour per address, and
            // GitHub says so with a 403 plus the reset time.
            if http.statusCode == 403 || http.statusCode == 429 {
                let reset = (http.value(forHTTPHeaderField: "x-ratelimit-reset")
                    .flatMap(Double.init))
                    .map { Date(timeIntervalSince1970: $0) }
                if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || reset != nil {
                    throw UpdateFeedError.rateLimited(until: reset)
                }
            }
            throw UpdateFeedError.httpStatus(http.statusCode)
        }

        return try Self.newestRelease(in: data, channel: channel, architecture: architecture)
    }

    /// The picking, split out from the fetching so it can be tested on fixtures.
    public static func newestRelease(
        in payload: Data,
        channel: UpdateChannel,
        architecture: String = GitHubUpdateFeed.machineArchitecture
    ) throws -> UpdateRelease? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let payloads: [ReleasePayload]
        do {
            payloads = try decoder.decode([ReleasePayload].self, from: payload)
        } catch {
            throw UpdateFeedError.decoding(error.localizedDescription)
        }

        return
            payloads
            .compactMap { $0.release(architecture: architecture) }
            .filter { channel.allowsPrerelease || !$0.isPrerelease }
            .max { $0.version < $1.version }
    }

    public static var machineArchitecture: String {
        #if arch(arm64)
            "arm64"
        #else
            "x86_64"
        #endif
    }

    private struct ReleasePayload: Decodable {
        var tagName: String
        var name: String?
        var body: String?
        var draft: Bool?
        var prerelease: Bool?
        var publishedAt: Date?
        var htmlUrl: URL?
        var assets: [AssetPayload]?

        struct AssetPayload: Decodable {
            var name: String
            var browserDownloadUrl: URL
            var size: Int?
        }

        func release(architecture: String) -> UpdateRelease? {
            guard draft != true, let version = AppVersion(tagName) else { return nil }
            // A tag can call itself stable while GitHub marks it a pre-release,
            // and the other way round. Either flag is enough to hold it back.
            let isPrerelease = prerelease == true || version.isPrerelease
            guard let asset = pickAsset(architecture: architecture) else { return nil }
            guard
                let pageURL = htmlUrl
                    ?? URL(string: "https://github.com/releases/tag/\(tagName)")
            else { return nil }

            return UpdateRelease(
                version: version,
                tag: tagName,
                name: name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? tagName,
                notes: body ?? "",
                isPrerelease: isPrerelease,
                publishedAt: publishedAt,
                pageURL: pageURL,
                asset: asset
            )
        }

        /// Architecture words a release asset might carry in its name. A zip
        /// naming none of them is taken to run anywhere.
        private static let architectureTokens = [
            "arm64", "aarch64", "apple-silicon", "x86_64", "x64", "amd64", "intel",
        ]

        private func pickAsset(architecture: String) -> UpdateAsset? {
            let wanted = architecture.lowercased()
            let zips = (assets ?? []).filter { $0.name.lowercased().hasSuffix(".zip") }
            // An asset naming this architecture wins. A zip that names no
            // architecture at all is taken as universal; one that names a
            // different machine is not offered, even if it is the only asset.
            let match =
                zips.first { $0.name.lowercased().contains(wanted) }
                ?? zips.first { $0.name.lowercased().contains("universal") }
                ?? zips.first { name in
                    !Self.architectureTokens.contains { name.name.lowercased().contains($0) }
                }
            guard let match else { return nil }
            return UpdateAsset(
                name: match.name,
                url: match.browserDownloadUrl,
                size: match.size ?? 0
            )
        }
    }
}
