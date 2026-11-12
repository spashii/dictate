import CryptoKit
import Foundation

/// What the Dictate site hands back after a code is verified: `dct1.<payload>.<signature>`,
/// where the payload is base64url JSON and the signature is Ed25519 over the bytes
/// `dct1.<payload>`. It names a signup by id, never an email, and has no expiry: the app never
/// compares its clock with the site's.
public struct ActivationToken: Equatable, Sendable {
    public let keyID: String
    public let signupID: String
    /// The random number this Mac made when it opened the activation page.
    public let nonce: String
    public let issuedAt: Date

    public enum Failure: Error, Equatable, Sendable {
        case malformed
        case unknownKey
        case badSignature
    }

    static let prefix = "dct1"

    private struct Payload: Decodable {
        let kid: String
        let sid: String
        let n: String
        let iat: Int
    }

    /// Checks the text against the keys this app trusts, which are compiled in. Whitespace
    /// around it is dropped, since the paste fallback brings whatever the clipboard held.
    public static func verify(_ text: String, keys: [String: Curve25519.Signing.PublicKey] = ActivationKeys.all) throws -> ActivationToken {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == prefix,
              let payloadBytes = Base64URL.decode(String(parts[1])),
              let signature = Base64URL.decode(String(parts[2])),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadBytes),
              !payload.sid.isEmpty, !payload.n.isEmpty
        else { throw Failure.malformed }
        guard let key = keys[payload.kid] else { throw Failure.unknownKey }
        let signed = Data("\(prefix).\(parts[1])".utf8)
        guard key.isValidSignature(signature, for: signed) else { throw Failure.badSignature }
        return ActivationToken(keyID: payload.kid, signupID: payload.sid, nonce: payload.n,
                               issuedAt: Date(timeIntervalSince1970: TimeInterval(payload.iat)))
    }
}

/// The public halves of the signing keys, by `kid`. A new key ships in an app update; a key
/// the site stops using is removed here to stop accepting new activations with it.
public enum ActivationKeys {
    /// Raw 32-byte keys, base64url. Filled in when the site's signing key is generated: until
    /// then no token verifies, which fails closed.
    static let encoded: [String: String] = [:]

    public static let all: [String: Curve25519.Signing.PublicKey] = encoded.compactMapValues {
        Base64URL.decode($0).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }
}

enum Base64URL {
    static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
