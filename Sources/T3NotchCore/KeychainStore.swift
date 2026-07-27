import Foundation
import Security

public enum KeychainStore {
    public static let service = "gg.t3tools.t3notch"
    public static let tokenAccount = "bearer-token"

    public enum Error: Swift.Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        public var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                return "Keychain error: \(status)"
            }
        }
    }

    public static func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Error.unexpectedStatus(status)
        }
        signatureOfSaver = currentSignature
    }

    /// Reads the saved token, or nil if the caller should mint a fresh one.
    ///
    /// A keychain item is readable without a prompt only by the exact signed binary
    /// that wrote it, and every build of T3Notch carries a new ad-hoc signature — so
    /// reading a token written by an earlier version asks for the login password. The
    /// token is a local session token that costs a second to re-mint, which is worth
    /// far less than that prompt: when the running binary is not the one that saved
    /// the item, drop it unread.
    public static func loadToken() -> String? {
        guard signatureOfSaver == currentSignature else {
            deleteToken()
            return nil
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
        ]
        SecItemDelete(query as CFDictionary)
        signatureOfSaver = nil
    }

    private static let signatureKey = service + ".tokenSignature"

    private static var signatureOfSaver: String? {
        get { UserDefaults.standard.string(forKey: signatureKey) }
        set { UserDefaults.standard.set(newValue, forKey: signatureKey) }
    }

    /// The running binary's code signature digest, which is what the keychain checks.
    private static var currentSignature: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let attributes = information as? [String: Any],
              let digest = attributes[kSecCodeInfoUnique as String] as? Data
        else { return nil }

        return digest.base64EncodedString()
    }
}
