import SwiftUI
import VoiceCore

/// What saving a hand correction in History did.
enum CorrectionOutcome {
    case failed(String)
    /// Saved, and no key term came of it.
    case saved
    case added(KeyTermAddition)
    /// Saved, and a line says why a proposed key term wasn't added.
    case note(String)
}

/// The key terms a correction added, and how to take them back out.
struct KeyTermAddition {
    let terms: [String]
    /// The errors of the terms that couldn't be taken out; empty when all were.
    let undo: () async -> [String]

    var message: String {
        switch terms.count {
        case 1: return "\(terms[0]) is now a key term."
        default: return "\(terms.dropLast().joined(separator: ", ")) and \(terms.last ?? "") are now key terms."
        }
    }
}

/// Where the correction popover points while a correction saves and the transcript redraws
/// the block with the corrected words. The redraw gives the block a new generation, which
/// closes an editor; one that is saving or confirming stays, moves to the corrected words,
/// and is closed by its own timer or by Undo.
struct CorrectionAnchor: Equatable {
    /// The words the popover points at, in the block's text.
    private(set) var range: Range<Int>
    private let original: Range<Int>
    private(set) var holding = false

    init(range: Range<Int>) {
        self.range = range
        original = range
    }

    /// The correction is saving: the popover outlives the redraw and points at the new words.
    mutating func hold(replacement: String) {
        range = range.lowerBound..<(range.lowerBound + replacement.utf16.count)
        holding = true
    }

    /// The save failed, so the form stays as it was.
    mutating func release() {
        range = original
        holding = false
    }

    /// Whether a new generation of the block closes the popover.
    var closesOnRefresh: Bool { !holding }
}

/// The correction popover once the correction is saved: a line saying what happened, with Undo
/// when a key term was added. It closes itself after a few seconds, so the person can ignore it,
/// and waits while the pointer is on it.
struct KeyTermConfirmation: View {
    let message: String
    let undo: (() async -> [String])?
    let done: () -> Void

    static let seconds = 5.0
    private static let tick = 0.1

    @State private var hovering = false
    @State private var left = Self.seconds
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(message)
                if let undo {
                    Button("Undo") {
                        Task {
                            if await undo().isEmpty {
                                done()
                            } else {
                                failure = "Couldn't take it out of your key terms."
                                left = Self.seconds
                            }
                        }
                    }
                    .buttonStyle(.link)
                }
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .onHover { hovering = $0 }
        .task(id: hovering) {
            while !hovering, left > 0 {
                try? await Task.sleep(for: .seconds(Self.tick))
                if Task.isCancelled { return }
                left -= Self.tick
            }
            if !hovering { done() }
        }
    }
}

extension KeyTermConfirmation {
    /// Said when whisper's prompt has no room for the proposed terms.
    static func full(_ terms: [String]) -> String {
        switch terms.count {
        case 1: return "Key terms are full. \(terms[0]) wasn't added."
        default: return "Key terms are full. \(terms.dropLast().joined(separator: ", ")) and \(terms.last ?? "") weren't added."
        }
    }

    static let addFailed = "Saved, but the key term couldn't be added."
}
