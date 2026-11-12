import SwiftUI

/// Voice's MIT license and the licenses of the libraries it includes, read from the files
/// bundled in the app, in a box that scrolls.
struct LicensesView: View {
    private let blocks = Self.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .textSelection(.enabled)
        }
        .frame(height: 240)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    @ViewBuilder
    private func view(_ block: NoticesDocument.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text).font(level == 1 ? .title3.weight(.semibold) : .headline).padding(.top, level == 1 ? 0 : 6)
        case .paragraph(let text):
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func load() -> [NoticesDocument.Block] {
        var blocks: [NoticesDocument.Block] = []
        if let license = text("LICENSE", nil) {
            blocks.append(.heading(level: 1, text: "\(AppName.name) license"))
            blocks.append(.code(license.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if let notices = text("THIRD_PARTY_NOTICES", "md") {
            blocks += NoticesDocument.parse(notices)
        }
        return blocks
    }

    private static func text(_ name: String, _ ext: String?) -> String? {
        Bundle.main.url(forResource: name, withExtension: ext).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
