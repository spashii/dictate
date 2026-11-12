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

    @Test func trustsNoKeyUntilOneIsCompiledIn() {
        #expect(throws: ActivationToken.Failure.unknownKey) {
            try ActivationToken.verify(TokenSupport.token())
        }
    }
}
