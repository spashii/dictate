import Foundation

/// THIRD_PARTY_NOTICES.md as blocks a view can lay out: headings, paragraphs and the license
/// texts in code fences. Only what that file uses is understood, so a heading, a paragraph
/// or a fence; anything else shows as the plain paragraph it is.
enum NoticesDocument {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case code(String)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func endParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    endParagraph()
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if line.hasPrefix("#") {
                endParagraph()
                let level = line.prefix { $0 == "#" }.count
                blocks.append(.heading(level: level, text: line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                endParagraph()
            } else {
                paragraph.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        endParagraph()
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        return blocks
    }
}
