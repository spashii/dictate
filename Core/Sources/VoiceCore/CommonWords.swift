import AppKit
import Foundation

/// Tells ordinary English from a name. A key term is a spelling whisper gets wrong, so a term
/// made only of everyday words ("quarterly roadmap", "harbour") is not worth listing: whisper
/// already spells those, and the suggestion is noise. A term with a digit, or with any word
/// the dictionary doesn't know ("OAuth", "T3 Code", "Szymon"), is kept.
public enum CommonWords {
    /// Whether a lower-case word is in the dictionary.
    public typealias Dictionary = @Sendable (String) -> Bool

    /// Set by the app: NSSpellChecker talks to a system service and expects the main thread,
    /// so checks made elsewhere are handed to it. dictate-cli has no main loop to hand them
    /// to and checks where it is.
    public static let onMainThread = Flag()

    public final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        public var isSet: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// The system's spelling dictionary, for US and British spellings. Words are checked in
    /// lower case, so a name that is also a word ("Orbit") counts as the word. When the
    /// spelling service doesn't answer, nothing is called common: it would otherwise call
    /// every word correct and hide every suggestion.
    public static let system: Dictionary = { word in
        if onMainThread.isSet, !Thread.isMainThread {
            return DispatchQueue.main.sync { check(word) }
        }
        return lock.withLock { check(word) }
    }

    private static func check(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        func known(_ word: String, _ language: String) -> Bool {
            checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        // A string no language has as a word: if it passes, the service isn't answering.
        guard !known("zqxjkvwy", "en_US") else { return false }
        return ["en_US", "en_GB"].contains { known(word, $0) }
    }

    /// NSSpellChecker is a shared object that isn't safe to call from two threads at once.
    private static let lock = NSLock()

    /// True when every word of the term is an ordinary word.
    public static func covers(_ term: String, in dictionary: Dictionary = system) -> Bool {
        let words = term.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }
        guard !words.isEmpty else { return false }
        return words.allSatisfy { word in
            word.count > 1 && word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" }
                && dictionary(word.lowercased().replacingOccurrences(of: "’", with: "'"))
        }
    }
}
