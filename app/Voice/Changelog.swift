import Foundation

/// CHANGELOG.md as entries About can list, and the notes of a Sparkle item as bullets. The
/// same file feeds the update feed (tools/changelog.sh), so what About shows for an update
/// and what it lists afterwards cannot differ.
enum Changelog {
    struct Entry: Equatable {
        var version: String
        var date: DateComponents?
        var items: [String]
    }

    /// Entries in file order, newest first. Anything before the first "## ", HTML comments
    /// and lines that are neither a heading nor a bullet are ignored.
    static func parse(_ markdown: String) -> [Entry] {
        var entries: [Entry] = []
        var inComment = false
        for raw in markdown.components(separatedBy: "\n") {
            var line = raw
            if inComment {
                guard let end = line.range(of: "-->") else { continue }
                line = String(line[end.upperBound...])
                inComment = false
            }
            while let start = line.range(of: "<!--") {
                if let end = line.range(of: "-->", range: start.upperBound..<line.endIndex) {
                    line.removeSubrange(start.lowerBound..<end.upperBound)
                } else {
                    line.removeSubrange(start.lowerBound...)
                    inComment = true
                }
            }
            if line.hasPrefix("## ") {
                let (version, date) = heading(String(line.dropFirst(3)))
                if !version.isEmpty { entries.append(Entry(version: version, date: date, items: [])) }
            } else if entries.isEmpty {
                continue
            } else if line.hasPrefix("- ") {
                entries[entries.count - 1].items.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if line.first == " " || line.first == "\t",
                      !line.trimmingCharacters(in: .whitespaces).isEmpty,
                      let last = entries[entries.count - 1].items.indices.last {
                entries[entries.count - 1].items[last] += " " + line.trimmingCharacters(in: .whitespaces)
            }
        }
        return entries
    }

    /// A bullet as styled text: **headline** in bold, the rest regular. Inline-only parsing keeps
    /// a bullet on one line, and a line without markers or with broken ones shows as written.
    static func styled(_ item: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnly)
        return (try? AttributedString(markdown: item, options: options)) ?? AttributedString(item)
    }

    /// How many releases What's new lists before View more.
    static let recentCount = 3

    /// The entries What's new lists: the newest few, or all of them once View more is pressed.
    static func visible(_ entries: [Entry], showingAll: Bool) -> [Entry] {
        showingAll ? entries : Array(entries.prefix(recentCount))
    }

    /// "0.14.0 (2026-11-13)" into the version and the date.
    private static func heading(_ text: String) -> (String, DateComponents?) {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard let version = parts.first else { return ("", nil) }
        guard parts.count > 1, parts[1].hasPrefix("("), parts[1].hasSuffix(")") else { return (version, nil) }
        let numbers = parts[1].dropFirst().dropLast().split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3 else { return (version, nil) }
        return (version, DateComponents(year: numbers[0], month: numbers[1], day: numbers[2]))
    }

    /// The bullets of a Sparkle item description: the text of each list item when it is HTML
    /// with a list, otherwise the non-empty lines of the text.
    static func bullets(fromDescription description: String) -> [String] {
        let items = matches(of: #"<li[^>]*>(.*?)</li>"#, in: description)
        if !items.isEmpty {
            return items.map { clean(stripTags(boldToMarkdown($0))) }.filter { !$0.isEmpty }
        }
        let broken = description.replacingOccurrences(of: #"<(br\s*/?|/p|/div)>"#, with: "\n",
                                                      options: [.regularExpression, .caseInsensitive])
        return stripTags(broken).components(separatedBy: .newlines).map(clean).filter { !$0.isEmpty }
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// <b>headline</b> back into **headline**, so a feed bullet styles like a CHANGELOG.md one.
    private static func boldToMarkdown(_ html: String) -> String {
        html.replacingOccurrences(of: #"<b>(.*?)</b>"#, with: "**$1**",
                                  options: [.regularExpression, .caseInsensitive])
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    }

    /// Decodes the entities and joins what was wrapped onto one line.
    private static func clean(_ text: String) -> String {
        var out = text
        // Numeric entities first, then the named ones, with &amp; last so "&amp;lt;" stays "&lt;".
        for (pattern, radix) in [("&#[xX]([0-9a-fA-F]+);", 16), ("&#([0-9]+);", 10)] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let found = regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed()
            for match in found {
                guard let whole = Range(match.range, in: out), let digits = Range(match.range(at: 1), in: out),
                      let value = UInt32(out[digits], radix: radix), let scalar = Unicode.Scalar(value) else { continue }
                out.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// True when `a` is an older version than `b`, comparing dotted numbers: 0.9.2 < 0.10.0.
    static func isOlder(_ a: String, than b: String) -> Bool {
        let x = numbers(a), y = numbers(b)
        for index in 0..<max(x.count, y.count) {
            let left = index < x.count ? x[index] : 0, right = index < y.count ? y[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
