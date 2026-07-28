import CryptoKit
import Foundation

public enum DPoPError: Error, LocalizedError, Sendable {
    case invalidURL
    case invalidPrivateKey
    case invalidPublicKey
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The DPoP target URL is invalid."
        case .invalidPrivateKey: "The DPoP private key is invalid."
        case .invalidPublicKey: "The DPoP public key is invalid."
        case .encodingFailed: "Could not encode the DPoP proof."
        }
    }
}

public struct DPoPPublicJWK: Codable, Equatable, Sendable {
    public let kty: String
    public let crv: String
    public let x: String
    public let y: String

    public init(kty: String = "EC", crv: String = "P-256", x: String, y: String) {
        self.kty = kty
        self.crv = crv
        self.x = x
        self.y = y
    }
}

public actor DPoPSigner {
    private let key: P256.Signing.PrivateKey
    public let privateKeyRawRepresentation: Data

    public init(privateKeyRawRepresentation: Data? = nil) throws {
        if let privateKeyRawRepresentation {
            do {
                key = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRawRepresentation)
            } catch {
                throw DPoPError.invalidPrivateKey
            }
        } else {
            key = P256.Signing.PrivateKey()
        }
        self.privateKeyRawRepresentation = key.rawRepresentation
    }

    public func publicJWK() throws -> DPoPPublicJWK {
        let raw = key.publicKey.x963Representation
        guard raw.count == 65, raw.first == 4 else {
            throw DPoPError.invalidPublicKey
        }
        return DPoPPublicJWK(
            x: Data(raw[1..<33]).base64URLEncodedString(),
            y: Data(raw[33..<65]).base64URLEncodedString()
        )
    }

    public func thumbprint() throws -> String {
        let jwk = try publicJWK()
        let canonical = #"{"crv":"P-256","kty":"EC","x":"\#(jwk.x)","y":"\#(jwk.y)"}"#
        return Data(SHA256.hash(data: Data(canonical.utf8))).base64URLEncodedString()
    }

    public func createProof(
        method: String,
        url: URL,
        accessToken: String? = nil,
        now: Date = .now,
        jti: UUID = UUID()
    ) throws -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased()
        else {
            throw DPoPError.invalidURL
        }
        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        {
            components.port = nil
        }
        components.query = nil
        components.fragment = nil
        guard let normalizedURL = components.url?.absoluteString else {
            throw DPoPError.invalidURL
        }

        let header = DPoPHeader(jwk: try publicJWK())
        var payload = DPoPPayload(
            htm: method.uppercased(),
            htu: normalizedURL,
            jti: jti.uuidString.lowercased(),
            iat: Int(now.timeIntervalSince1970),
            ath: nil
        )
        if let accessToken {
            payload.ath = Data(SHA256.hash(data: Data(accessToken.utf8))).base64URLEncodedString()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encodedHeader = try encoder.encode(header).base64URLEncodedString()
        let encodedPayload = try encoder.encode(payload).base64URLEncodedString()
        let signingInput = Data("\(encodedHeader).\(encodedPayload)".utf8)
        let signature = try key.signature(for: signingInput).rawRepresentation
        guard signature.count == 64 else { throw DPoPError.encodingFailed }
        return "\(encodedHeader).\(encodedPayload).\(signature.base64URLEncodedString())"
    }
}

private struct DPoPHeader: Encodable {
    let typ = "dpop+jwt"
    let alg = "ES256"
    let jwk: DPoPPublicJWK
}

private struct DPoPPayload: Encodable {
    let htm: String
    let htu: String
    let jti: String
    let iat: Int
    var ath: String?
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
