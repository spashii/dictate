import CryptoKit
import Foundation
import Testing
@testable import VoiceCore

/// Tokens here are signed with a throwaway key made by the test, in the format the site mints.
enum TokenSupport {
    static let key = Curve25519.Signing.PrivateKey()

    static func token(kid: String = "k1", sid: String = "s1a2b3c4d5e6", nonce: String = "n0nce", iat: Int = 1_794_000_000,
                      signedWith signer: Curve25519.Signing.PrivateKey = key) -> String {
        let json = #"{"kid":"\#(kid)","sid":"\#(sid)","n":"\#(nonce)","iat":\#(iat)}"#
        let payload = Base64URL.encode(Data(json.utf8))
        let signature = try! signer.signature(for: Data("dct1.\(payload)".utf8))
        return "dct1.\(payload).\(Base64URL.encode(signature))"
    }

    static let keys = ["k1": key.publicKey]
}

@Suite struct ActivationTokenTests {
    @Test func verifiesAValidToken() throws {
        let token = try ActivationToken.verify(TokenSupport.token(), keys: TokenSupport.keys)
        #expect(token.signupID == "s1a2b3c4d5e6")
        #expect(token.nonce == "n0nce")
        #expect(token.keyID == "k1")
        #expect(token.issuedAt == Date(timeIntervalSince1970: 1_794_000_000))
    }

    @Test func ignoresWhitespaceFromAPaste() throws {
        let text = "  \n" + TokenSupport.token() + " \n"
        #expect(try ActivationToken.verify(text, keys: TokenSupport.keys).nonce == "n0nce")
    }

    @Test func refusesATamperedPayload() {
        let parts = TokenSupport.token().split(separator: ".").map(String.init)
        let forged = Base64URL.encode(Data(#"{"kid":"k1","sid":"someone-else","n":"n0nce","iat":1794000000}"#.utf8))
        #expect(throws: ActivationToken.Failure.badSignature) {
            try ActivationToken.verify("dct1.\(forged).\(parts[2])", keys: TokenSupport.keys)
        }
    }

    @Test func refusesATamperedSignature() {
        var text = TokenSupport.token()
        text.removeLast()
        text.append(text.last == "A" ? "B" : "A")
        #expect(throws: ActivationToken.Failure.badSignature) {
            try ActivationToken.verify(text, keys: TokenSupport.keys)
        }
    }

    @Test func refusesAnotherKeysSignature() {
        let text = TokenSupport.token(signedWith: Curve25519.Signing.PrivateKey())
        #expect(throws: ActivationToken.Failure.badSignature) {
            try ActivationToken.verify(text, keys: TokenSupport.keys)
        }
    }

    @Test func refusesAnUnknownKid() {
        #expect(throws: ActivationToken.Failure.unknownKey) {
            try ActivationToken.verify(TokenSupport.token(kid: "k9"), keys: TokenSupport.keys)
        }
    }

    @Test func refusesMalformedText() {
        let good = TokenSupport.token()
        let payload = good.split(separator: ".")[1]
        for text in ["", "dct1", "dct1.a", "dct1..", "dct2.\(payload).AAAA", "dct1.\(payload)",
                     "dct1.\(payload).AAAA.extra", "dct1.!!!.AAAA", "dct1.\(payload).!!!",
                     "dct1.\(Base64URL.encode(Data("not json".utf8))).AAAA",
                     TokenSupport.token(sid: ""), TokenSupport.token(nonce: "")] {
            #expect(throws: ActivationToken.Failure.malformed, "\(text)") {
                try ActivationToken.verify(text, keys: TokenSupport.keys)
            }
        }
    }

    @Test func theCompiledInKeysAreNotEmpty() {
        #expect(ActivationKeys.encoded.count == 1)
        #expect(ActivationKeys.all.keys.sorted() == ["k1"])
    }

    @Test func refusesATokenNotSignedByTheCompiledInKey() {
        #expect(throws: ActivationToken.Failure.badSignature) {
            try ActivationToken.verify(TokenSupport.token())
        }
    }
}

/// A token minted by the site's own signer (dictate-web `test/fixtures/activation-token.json`),
/// so the two sides agree on the bytes that are signed.
@Suite struct WorkerFixtureTests {
    static let key = "E2DuHBFTI9GCt-8qDb1Mt3exNfS1xlhreV6lD_qPT0U"
    static let token = "dct1.eyJraWQiOiJrMSIsInNpZCI6InMxYTJiM2M0ZDVlNiIsIm4iOiJBQUVDQXdRRkJnY0lDUW9MREEwT0R3IiwiaWF0IjoxNzk0MDAwMDAwfQ.RnpG_GUry7fZmDb3C0f9x3pRT2GXronksYhu3WmZglVsG0PQTmfL1lWcrHBsYoO3RZmrX3lHM-nb9BTxt9OjBA"

    var keys: [String: Curve25519.Signing.PublicKey] {
        ["k1": try! Curve25519.Signing.PublicKey(rawRepresentation: Base64URL.decode(Self.key)!)]
    }

    @Test func verifiesTheSitesToken() throws {
        let token = try ActivationToken.verify(Self.token, keys: keys)
        #expect(token.signupID == "s1a2b3c4d5e6")
        #expect(token.nonce == "AAECAwQFBgcICQoLDA0ODw")
        #expect(token.issuedAt == Date(timeIntervalSince1970: 1_794_000_000))
    }

    @Test func refusesItOnceTampered() {
        let parts = Self.token.split(separator: ".")
        let forged = Base64URL.encode(Data(#"{"kid":"k1","sid":"x","n":"AAECAwQFBgcICQoLDA0ODw","iat":1794000000}"#.utf8))
        #expect(throws: ActivationToken.Failure.badSignature) {
            try ActivationToken.verify("dct1.\(forged).\(parts[2])", keys: keys)
        }
    }
}
