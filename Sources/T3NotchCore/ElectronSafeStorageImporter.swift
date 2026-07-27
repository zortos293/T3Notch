import CCommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum T3ConnectSessionDetection: Equatable, Sendable {
    case unavailable
    case signedOut
    case signedIn(ciphertextFingerprint: String)
    case unsafePermissions
    case incompatible(String)
}

public struct ImportedElectronSession: Sendable, Equatable {
    public let clientJWT: String
    public let ciphertextFingerprint: String

    public init(clientJWT: String, ciphertextFingerprint: String) {
        self.clientJWT = clientJWT
        self.ciphertextFingerprint = ciphertextFingerprint
    }
}

public enum ElectronSafeStorageError: Error, LocalizedError, Sendable {
    case fileUnsafe
    case unsafePermissions
    case formatUnsupported
    case keychainDenied
    case decryptionFailed
    case invalidSession

    public var errorDescription: String? {
        switch self {
        case .fileUnsafe: "T3 Code's session file did not pass local security checks."
        case .unsafePermissions:
            "T3 Code's session file is writable by other local users."
        case .formatUnsupported:
            "This T3 Code sign-in format is not supported by this T3Notch version."
        case .keychainDenied: "T3 Code's Keychain encryption key was not made available."
        case .decryptionFailed: "The T3 Code session could not be decrypted."
        case .invalidSession: "T3 Code's saved sign-in is invalid or expired."
        }
    }
}

public struct ElectronSafeStorageImporter: Sendable {
    public static let tokenKey = "__clerk_client_jwt"
    public static let keychainService = "t3code Safe Storage"
    public static let keychainAccount = "t3code Key"

    public let tokenFile: URL

    public init(
        tokenFile: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata/clerk-tokens.json")
    ) {
        self.tokenFile = tokenFile
    }

    /// Performs only filesystem/schema checks. It never reads T3 Code's
    /// Keychain item, so settings can safely call this on launch and activation.
    public func detect() -> T3ConnectSessionDetection {
        guard FileManager.default.fileExists(atPath: tokenFile.path) else {
            return .unavailable
        }
        do {
            let encrypted = try readEncryptedRecord()
            let fingerprint = Self.sha256(encrypted)
            return .signedIn(ciphertextFingerprint: fingerprint)
        } catch ElectronSafeStorageError.unsafePermissions {
            return .unsafePermissions
        } catch ElectronSafeStorageError.invalidSession {
            return .signedOut
        } catch {
            return .incompatible(error.localizedDescription)
        }
    }

    /// This is intentionally the only API that may prompt for T3 Code's
    /// Safe Storage Keychain item.
    public func importSession() throws -> ImportedElectronSession {
        let encrypted = try readEncryptedRecord()
        guard encrypted.hasPrefix("enc:"),
              let bytes = Data(base64Encoded: String(encrypted.dropFirst(4))),
              bytes.starts(with: Data("v10".utf8))
        else {
            throw ElectronSafeStorageError.formatUnsupported
        }
        let password = try readSafeStoragePassword()
        let clientJWT = try Self.decryptV10(Data(bytes.dropFirst(3)), password: password)
        guard Self.isJWT(clientJWT) else {
            throw ElectronSafeStorageError.invalidSession
        }
        return ImportedElectronSession(
            clientJWT: clientJWT,
            ciphertextFingerprint: Self.sha256(encrypted)
        )
    }

    private func readEncryptedRecord() throws -> String {
        let values = try tokenFile.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ElectronSafeStorageError.fileUnsafe
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: tokenFile.path)
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        guard owner == getuid(), let permissions else {
            throw ElectronSafeStorageError.fileUnsafe
        }
        guard permissions & 0o022 == 0 else {
            throw ElectronSafeStorageError.unsafePermissions
        }
        let data = try Data(contentsOf: tokenFile, options: [.mappedIfSafe])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ElectronSafeStorageError.formatUnsupported
        }
        guard let value = object[Self.tokenKey] as? String else {
            throw ElectronSafeStorageError.invalidSession
        }
        guard !value.isEmpty else { throw ElectronSafeStorageError.invalidSession }
        return value
    }

    private func readSafeStoragePassword() throws -> Data {
        let context = LAContext()
        context.localizedReason = "Import your T3 Connect sign-in into T3Notch."
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else {
            throw ElectronSafeStorageError.keychainDenied
        }
        return data
    }

    static func decryptV10(_ ciphertext: Data, password: Data) throws -> String {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let derivationStatus = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        kCCKeySizeAES128
                    )
                }
            }
        }
        guard derivationStatus == kCCSuccess else {
            throw ElectronSafeStorageError.decryptionFailed
        }

        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let outputCapacity = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var moved = 0
        let cryptStatus = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            ciphertext.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        key.resetBytes(in: 0..<key.count)
        guard cryptStatus == kCCSuccess else {
            throw ElectronSafeStorageError.decryptionFailed
        }
        output.removeSubrange(moved..<output.count)
        guard let value = String(data: output, encoding: .utf8) else {
            throw ElectronSafeStorageError.decryptionFailed
        }
        return value
    }

    private static func isJWT(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        for part in parts.prefix(2) {
            var encoded = String(part)
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let data = Data(base64Encoded: encoded),
                  (try? JSONSerialization.jsonObject(with: data)) != nil
            else {
                return false
            }
        }
        return true
    }

    private static func sha256(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64URLEncodedString()
    }
}
