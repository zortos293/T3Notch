import Foundation

public final class EnvironmentProfileStore: @unchecked Sendable {
    private struct Document: Codable {
        var version = 1
        var profiles: [EnvironmentProfile]
    }

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        key: String = "gg.t3tools.t3notch.environmentProfiles.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [EnvironmentProfile] {
        lock.withLock {
            guard let data = defaults.data(forKey: key),
                  let document = try? JSONDecoder().decode(Document.self, from: data),
                  document.version == 1
            else {
                return []
            }
            return document.profiles
        }
    }

    public func save(_ profiles: [EnvironmentProfile]) throws {
        try lock.withLock {
            let data = try JSONEncoder().encode(Document(profiles: profiles))
            defaults.set(data, forKey: key)
        }
    }

    public func upsert(_ profile: EnvironmentProfile) throws {
        var profiles = load()
        if let index = profiles.firstIndex(where: { $0.environmentID == profile.environmentID }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try save(profiles)
    }

    public func remove(_ environmentID: EnvironmentID) throws {
        try save(load().filter { $0.environmentID != environmentID })
    }
}
