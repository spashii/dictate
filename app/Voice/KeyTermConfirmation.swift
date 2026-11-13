import SwiftUI
import VoiceCore

/// What saving a hand correction in History did.
enum CorrectionOutcome {
    case failed(String)
    /// Saved, and no key term came of it.
    case saved
    case added(KeyTermAddition)
    /// A key term was proposed and the list refused it.
    case refused
}

/// The key terms a correction added, and how to take them back out.
struct KeyTermAddition {
    let terms: [String]
    let undo: () async -> Void

    var message: String {
        switch terms.count {
        case 1: return "\(terms[0]) is now a key term."
        default: return "\(terms.dropLast().joined(separator: ", ")) and \(terms.last ?? "") are now key terms."
        }
    }
}

/// The correction popover once the correction is saved: a line saying what happened, with Undo
/// when a key term was added. It closes itself after a few seconds, so the person can ignore it.
struct KeyTermConfirmation: View {
    let message: String
    let undo: (() async -> Void)?
    let done: () -> Void

    static let seconds = 5

    var body: some View {
        HStack(spacing: 10) {
            Text(message)
            if let undo {
                Button("Undo") {
                    Task {
                        await undo()
                        done()
                    }
                }
                .buttonStyle(.link)
            }
        }
        .padding(12)
        .task {
            try? await Task.sleep(for: .seconds(Self.seconds))
            if !Task.isCancelled { done() }
        }
    }
}

extension KeyTermConfirmation {
    static let full = "Key terms are full, so it wasn't added."
}
