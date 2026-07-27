import Foundation
import LocalAuthentication
import Security

public struct RemoteAccessCredential: Codable, Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date
    public var source: EnvironmentSource

    public init(accessToken: String, expiresAt: Date, source: EnvironmentSource) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.source = source
    }

    public var needsRefresh: Bool {
        expiresAt.timeIntervalSinceNow <= 300
    }
}

public struct ImportedT3ConnectCredential: Codable, Sendable, Equatable {
    public var clerkClientJWT: String
    public var ciphertextFingerprint: String

    public init(clerkClientJWT: String, ciphertextFingerprint: String) {
        self.clerkClientJWT = clerkClientJWT
        self.ciphertextFingerprint = ciphertextFingerprint
    }
}

public struct RemoteCredentialDocument: Codable, Sendable, Equatable {
    public var version = 1
    /// Direct-pairing grants are intentionally kept separate from relay-minted
    /// grants. A logical environment may have both access paths, and falling
    /// back to Connect must never destroy the credential needed to switch back.
    public var environmentCredentials: [String: RemoteAccessCredential] = [:]
    public var connectEnvironmentCredentials: [String: RemoteAccessCredential] = [:]
    public var relayAccessTokens: [String: RemoteAccessCredential] = [:]
    public var importedT3Connect: ImportedT3ConnectCredential?
    public var dpopPrivateKey: Data?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version
        case environmentCredentials
        case connectEnvironmentCredentials
        case relayAccessTokens
        case importedT3Connect
        case dpopPrivateKey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        environmentCredentials = try container.decodeIfPresent(
            [String: RemoteAccessCredential].self,
            forKey: .environmentCredentials
        ) ?? [:]
        connectEnvironmentCredentials = try container.decodeIfPresent(
            [String: RemoteAccessCredential].self,
            forKey: .connectEnvironmentCredentials
        ) ?? [:]
        relayAccessTokens = try container.decodeIfPresent(
            [String: RemoteAccessCredential].self,
            forKey: .relayAccessTokens
        ) ?? [:]
        importedT3Connect = try container.decodeIfPresent(
            ImportedT3ConnectCredential.self,
            forKey: .importedT3Connect
        )
        dpopPrivateKey = try container.decodeIfPresent(Data.self, forKey: .dpopPrivateKey)
    }
}

public enum RemoteCredentialVaultError: Error, LocalizedError, Sendable {
    case locked
    case invalidDocument
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .locked: "Remote credentials are locked. Unlock them in Settings."
        case .invalidDocument: "The remote credential vault is damaged."
        case let .unexpectedStatus(status): "Keychain error: \(status)"
        }
    }
}

public protocol RemoteCredentialStoring: Sendable {
    func document() throws -> RemoteCredentialDocument
    func update(
        _ transform: (inout RemoteCredentialDocument) throws -> Void
    ) throws
    func forgetT3Connect() throws
}

public final class RemoteCredentialVault: RemoteCredentialStoring, @unchecked Sendable {
    public static let service = "gg.t3tools.t3notch"
    public static let account = "remote-credential-vault-v1"

    private let lock = NSLock()
    private var cached: RemoteCredentialDocument?

    public init() {}

    public func loadWithoutPrompt() throws -> RemoteCredentialDocument {
        try load(allowsInteraction: false)
    }

    public func unlock() throws -> RemoteCredentialDocument {
        try load(allowsInteraction: true)
    }

    public func document() throws -> RemoteCredentialDocument {
        if let cached = lock.withLock({ self.cached }) {
            return cached
        }
        return try loadWithoutPrompt()
    }

    public func update(
        _ transform: (inout RemoteCredentialDocument) throws -> Void
    ) throws {
        var document: RemoteCredentialDocument
        do {
            document = try self.document()
        } catch RemoteCredentialVaultError.unexpectedStatus(errSecItemNotFound) {
            document = RemoteCredentialDocument()
        }
        try transform(&document)
        try save(document)
    }

    public func save(_ document: RemoteCredentialDocument) throws {
        let data = try JSONEncoder().encode(document)
        let query = baseQuery
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw RemoteCredentialVaultError.unexpectedStatus(updateStatus)
            }
        } else if status != errSecSuccess {
            throw RemoteCredentialVaultError.unexpectedStatus(status)
        }
        lock.withLock { cached = document }
    }

    public func removeEnvironment(_ environmentID: EnvironmentID) throws {
        try update { document in
            document.environmentCredentials.removeValue(forKey: environmentID.rawValue)
            document.connectEnvironmentCredentials.removeValue(forKey: environmentID.rawValue)
        }
    }

    public func forgetT3Connect() throws {
        try update { document in
            document.importedT3Connect = nil
            document.relayAccessTokens = [:]
            document.connectEnvironmentCredentials = [:]
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    private func load(allowsInteraction: Bool) throws -> RemoteCredentialDocument {
        if let cached = lock.withLock({ self.cached }) {
            return cached
        }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = !allowsInteraction
        if allowsInteraction {
            context.localizedReason = "Unlock T3Notch remote machine credentials."
        }
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            let empty = RemoteCredentialDocument()
            lock.withLock { cached = empty }
            return empty
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            throw RemoteCredentialVaultError.locked
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw RemoteCredentialVaultError.unexpectedStatus(status)
        }
        guard let document = try? JSONDecoder().decode(RemoteCredentialDocument.self, from: data),
              document.version == 1
        else {
            throw RemoteCredentialVaultError.invalidDocument
        }
        lock.withLock { cached = document }
        return document
    }
}
