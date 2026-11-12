import XCTest

final class NoticesDocumentTests: XCTestCase {
    func testHeadingsParagraphsAndFences() {
        let text = """
        # Third-party notices

        Dictate includes the following
        software.

        ## whisper.cpp

        https://example.com, release 1.

        ```
        MIT License

        Copyright (c) 2023
        ```
        """
        XCTAssertEqual(NoticesDocument.parse(text), [
            .heading(level: 1, text: "Third-party notices"),
            .paragraph("Dictate includes the following software."),
            .heading(level: 2, text: "whisper.cpp"),
            .paragraph("https://example.com, release 1."),
            .code("MIT License\n\nCopyright (c) 2023"),
        ])
    }

    /// A # inside a license text is not a heading.
    func testFenceKeepsHashLines() {
        XCTAssertEqual(NoticesDocument.parse("```\n# not a heading\n```"), [.code("# not a heading")])
    }

    func testUnclosedFenceStillShowsItsText() {
        XCTAssertEqual(NoticesDocument.parse("```\nlicense text"), [.code("license text")])
    }

    func testTheShippedFileParsesToSomething() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "THIRD_PARTY_NOTICES.md")
        let blocks = NoticesDocument.parse(try String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(blocks.contains { if case .code = $0 { true } else { false } })
        XCTAssertEqual(blocks.first, .heading(level: 1, text: "Third-party notices"))
    }
}
