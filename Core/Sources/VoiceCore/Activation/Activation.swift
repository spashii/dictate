import CryptoKit
import Foundation
import Observation

/// What is kept between launches, apart from the nonce: the signed token and when the 7 day
/// grace began. One record, so deleting the Keychain item resets both.
public struct ActivationRecord: Codable, Equatable, Sendable {
    public var token: String?
    public var graceStart: Date?

    public init(token: String? = nil, graceStart: Date? = nil) {
        self.token = token
        self.graceStart = graceStart
    }
}

/// Where the record lives: the login Keychain in the app, memory in tests, since a headless
/// test run cannot answer a Keychain prompt.
public protocol ActivationStore: AnyObject {
    func load() -> ActivationRecord
    func save(_ record: ActivationRecord)
}

public final class MemoryActivationStore: ActivationStore {
    public var record: ActivationRecord

    public init(_ record: ActivationRecord = ActivationRecord()) {
        self.record = record
    }

    public func load() -> ActivationRecord { record }
    public func save(_ record: ActivationRecord) { self.record = record }
}

/// Whether this Mac may dictate and record calls, and the steps that change that.
@MainActor @Observable
public final class Activation {
    public enum State: Equatable, Sendable {
        case locked
        /// The activation page was opened with this nonce and the token has not come back.
        case pending(nonce: String)
        case activated
        case grace(until: Date)
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// Not a token this app trusts: wrong text, tampered, or signed with an unknown key.
        case invalid
        /// A genuine token, but for a request this Mac did not make.
        case otherRequest
    }

    public static let graceLength: TimeInterval = 7 * 24 * 3600
    public static let nonceLifetime: TimeInterval = 24 * 3600

    private enum Key {
        static let nonce = "activationNonce"
        static let nonceDate = "activationNonceDate"
        static let pressed = "activationPressed"
    }

    @ObservationIgnored private let store: ActivationStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let keys: [String: Curve25519.Signing.PublicKey]
    @ObservationIgnored private let makeNonce: () -> String

    public private(set) var state: State = .locked

    public init(store: ActivationStore, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
                keys: [String: Curve25519.Signing.PublicKey] = ActivationKeys.all,
                makeNonce: @escaping () -> String = Activation.randomNonce) {
        self.store = store
        self.defaults = defaults
        self.now = now
        self.keys = keys
        self.makeNonce = makeNonce
        refresh()
    }

    /// Dictation, call recording and an agent's start_recording all ask this.
    public var allowsRecording: Bool {
        switch state {
        case .activated, .grace: true
        case .locked, .pending: false
        }
    }

    /// The 7 days are offered once the person has pressed Activate, and once per Mac: a used
    /// grace is never offered again, whether it is running or over.
    public var canOfferGrace: Bool {
        !allowsRecording && defaults.bool(forKey: Key.pressed) && store.load().graceStart == nil
    }

    /// Recomputes the state, for the clock moving on (the grace ending) and for a changed store.
    public func refresh() {
        let record = store.load()
        if let text = record.token, (try? ActivationToken.verify(text, keys: keys)) != nil {
            state = .activated
        } else if let start = record.graceStart, start.addingTimeInterval(Self.graceLength) > now() {
            state = .grace(until: start.addingTimeInterval(Self.graceLength))
        } else if let nonce = pendingNonce {
            state = .pending(nonce: nonce)
        } else {
            state = .locked
        }
    }

    /// The nonce for the activation page. One made less than a day ago is reused, so a page
    /// left open in an older tab still works.
    @discardableResult
    public func begin() -> String {
        defaults.set(true, forKey: Key.pressed)
        let nonce = pendingNonce ?? makeNonce()
        if pendingNonce == nil {
            defaults.set(nonce, forKey: Key.nonce)
            defaults.set(now(), forKey: Key.nonceDate)
        }
        refresh()
        return nonce
    }

    /// The address to open: the page, with the nonce and version in the fragment so they
    /// never go to a server in a request.
    public func pageURL(base: URL, version: String) -> URL {
        let nonce = begin()
        return URL(string: base.appending(path: "activate").absoluteString + "#n=\(nonce)&v=\(version)")!
    }

    public func startGrace() {
        guard canOfferGrace else { return }
        var record = store.load()
        record.graceStart = now()
        store.save(record)
        refresh()
    }

    /// A link in the app's scheme: `<scheme>://activate?t=<token>`.
    @discardableResult
    public func accept(url: URL) -> Result<Void, Refusal> {
        guard url.host == "activate",
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                  .first(where: { $0.name == "t" })?.value
        else { return .failure(.invalid) }
        return accept(text: token)
    }

    /// The token as text, from the link or the paste field. Nothing is stored unless it is
    /// genuine and carries this Mac's pending nonce.
    @discardableResult
    public func accept(text: String) -> Result<Void, Refusal> {
        let token: ActivationToken
        do { token = try ActivationToken.verify(text, keys: keys) } catch { return .failure(.invalid) }
        guard let nonce = pendingNonce, token.nonce == nonce else { return .failure(.otherRequest) }
        var record = store.load()
        record.token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save(record)
        defaults.removeObject(forKey: Key.nonce)
        defaults.removeObject(forKey: Key.nonceDate)
        refresh()
        return .success(())
    }

    private var pendingNonce: String? {
        guard let nonce = defaults.string(forKey: Key.nonce),
              let made = defaults.object(forKey: Key.nonceDate) as? Date,
              now().timeIntervalSince(made) < Self.nonceLifetime else { return nil }
        return nonce
    }

    public nonisolated static func randomNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return Base64URL.encode(Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }
}
