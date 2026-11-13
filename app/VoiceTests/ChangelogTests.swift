import XCTest

final class ChangelogTests: XCTestCase {
    func testParsesEntriesNewestFirst() {
        let text = """
        # What's new

        <!--
        ## 9.9.9 (2000-01-01)
        - hidden
        -->

        Some words before the first entry.

        ## 1.2.0 (2026-11-13)

        - Drop a file on History.
        - A long line that
          wraps onto the next one.
        unknown line
        * not a bullet

        ## 1.1.0
        - Older change.
        """
        let entries = Changelog.parse(text)
        XCTAssertEqual(entries.map(\.version), ["1.2.0", "1.1.0"])
        XCTAssertEqual(entries[0].date, DateComponents(year: 2026, month: 11, day: 13))
        XCTAssertEqual(entries[0].items, ["Drop a file on History.", "A long line that wraps onto the next one."])
        XCTAssertNil(entries[1].date)
        XCTAssertEqual(entries[1].items, ["Older change."])
    }

    func testBulletsFromHTML() {
        let html = "<ul><li>Fish &amp; chips</li><li>Use <b>&lt;b&gt;</b> &quot;now&quot; it&#39;s &#8217;ok&#x2019;</li></ul>"
        XCTAssertEqual(Changelog.bullets(fromDescription: html),
                       ["Fish & chips", "Use <b> \"now\" it's \u{2019}ok\u{2019}"])
    }

    func testBulletsFromPlainText() {
        XCTAssertEqual(Changelog.bullets(fromDescription: "First thing.\n\n  Second thing.\n"), ["First thing.", "Second thing."])
        XCTAssertEqual(Changelog.bullets(fromDescription: "<p>One</p><p>Two</p>"), ["One", "Two"])
        XCTAssertEqual(Changelog.bullets(fromDescription: ""), [])
    }

    func testVersionOrder() {
        XCTAssertTrue(Changelog.isOlder("0.9.2", than: "0.10.0"))
        XCTAssertFalse(Changelog.isOlder("0.10.0", than: "0.9.2"))
        XCTAssertFalse(Changelog.isOlder("1.0", than: "1.0.0"))
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    func testRealChangelog() throws {
        let text = try String(contentsOf: Self.root.appending(path: "CHANGELOG.md"), encoding: .utf8)
        let version = try String(contentsOf: Self.root.appending(path: "VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = Changelog.parse(text)
        XCTAssertGreaterThanOrEqual(entries.count, 6)
        XCTAssertEqual(entries.first?.version, version)
        for entry in entries {
            XCTAssertNotNil(entry.date, entry.version)
            XCTAssertFalse(entry.items.isEmpty, entry.version)
        }
        XCTAssertFalse(text.contains("\u{2014}"))
        XCTAssertFalse(text.contains("\u{2013}"))
    }
}
