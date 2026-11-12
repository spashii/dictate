import AppKit
import Foundation

/// Tells ordinary English from a name. A key term is a spelling whisper gets wrong, so a term
/// made only of everyday words ("quarterly roadmap", "harbour") is not worth listing: whisper
/// already spells those, and the suggestion is noise. A term with a digit, or with any word
/// the dictionary doesn't know ("OAuth", "T3 Code", "Szymon"), is kept.
public enum CommonWords {
    /// Whether a lower-case word is in the dictionary.
    public typealias Dictionary = @Sendable (String) -> Bool

    /// The system's spelling dictionary, for US and British spellings. Words are checked in
    /// lower case, so a name that is also a word ("Orbit") counts as the word.
    public static let system: Dictionary = { word in
        lock.withLock {
            let checker = NSSpellChecker.shared
            return ["en_US", "en_GB"].contains { language in
                checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                      inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
            }
        }
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
