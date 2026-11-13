import Foundation

/// Puts a corrected text back into the lines it was made from.
enum LineAlignment {
    /// Past this many token pairs the table is too big to be worth it.
    static let limit = 4_000_000

    /// `corrected`'s words in the lines of `lines`. A word that is unchanged stays in its line,
    /// words that replace others take the line of the first they replaced, and words added
    /// between others take the line before. Nil when the texts are too long to line up.
    static func realign(_ lines: [String], to corrected: String) -> [String]? {
        guard !lines.isEmpty else { return nil }
        var original: [(word: Substring, line: Int)] = []
        for (index, text) in lines.enumerated() {
            for word in text.split(whereSeparator: \.isWhitespace) { original.append((word, index)) }
        }
        let after = corrected.split(whereSeparator: \.isWhitespace)
        let (n, m) = (original.count, after.count)
        guard n * m <= limit else { return nil }
        // best[i][j]: the most words the tails original[i...] and after[j...] share.
        var best = [[UInt16]](repeating: [UInt16](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    best[i][j] = original[i].word == after[j] ? best[i + 1][j + 1] + 1 : max(best[i + 1][j], best[i][j + 1])
                }
            }
        }
        var out = [[Substring]](repeating: [], count: lines.count)
        var (i, j) = (0, 0)
        var last = original.first?.line ?? 0
        var run: Int?
        while j < m {
            if i < n, original[i].word == after[j] {
                last = original[i].line
                out[last].append(after[j])
                run = nil
                i += 1
                j += 1
            } else if i < n, best[i + 1][j] >= best[i][j + 1] {
                run = run ?? original[i].line
                i += 1
            } else {
                out[run ?? last].append(after[j])
                j += 1
            }
        }
        return out.map { $0.joined(separator: " ") }
    }
}
