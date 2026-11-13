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

        - **Import audio files.** Drop a file on History.
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
        XCTAssertEqual(entries[0].items, ["**Import audio files.** Drop a file on History.", "A long line that wraps onto the next one."])
        XCTAssertNil(entries[1].date)
        XCTAssertEqual(entries[1].items, ["Older change."])
    }

    func testBulletsFromHTML() {
        let html = "<ul><li>Fish &amp; chips</li><li>Use &lt;b&gt; &quot;now&quot; it&#39;s &#8217;ok&#x2019;</li><li><b>Import.</b> Drop a file.</li></ul>"
        XCTAssertEqual(Changelog.bullets(fromDescription: html),
                       ["Fish & chips", "Use <b> \"now\" it's \u{2019}ok\u{2019}", "**Import.** Drop a file."])
    }

    func testStyledBulletBoldsOnlyTheHeadline() {
        let styled = Changelog.styled("**Import audio files.** Drop a file on History.")
        XCTAssertEqual(String(styled.characters), "Import audio files. Drop a file on History.")
        let bold = styled.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertEqual(bold.map { String(styled[$0.range].characters) }, ["Import audio files."])
        XCTAssertEqual(String(Changelog.styled("No headline here.").characters), "No headline here.")
        XCTAssertEqual(String(Changelog.styled("Open **unclosed").characters), "Open **unclosed")
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
        var entries = Changelog.parse(text)
        // The next release's entry is written with its change and stays undated until the
        // release sets VERSION and the date.
        if let next = entries.first, next.version != version, next.date == nil {
            XCTAssertFalse(next.items.isEmpty, next.version)
            XCTAssertTrue(Changelog.isOlder(version, than: next.version), next.version)
            entries.removeFirst()
        }
        XCTAssertGreaterThanOrEqual(entries.count, 6)
        XCTAssertEqual(entries.first?.version, version)
        for entry in entries {
            XCTAssertNotNil(entry.date, entry.version)
            XCTAssertFalse(entry.items.isEmpty, entry.version)
        }
        for entry in entries {
            for item in entry.items { XCTAssertTrue(item.hasPrefix("**"), "\(entry.version): \(item)") }
        }
        XCTAssertFalse(text.contains("\u{2014}"))
        XCTAssertFalse(text.contains("\u{2013}"))
    }

    func testWhatsNewShowsTheLastThreeReleasesUntilViewMore() {
        let entries = ["1.5.0", "1.4.0", "1.3.0", "1.2.0", "1.1.0"].map {
            Changelog.Entry(version: $0, date: nil, items: ["A change."])
        }
        XCTAssertEqual(Changelog.visible(entries, showingAll: false).map(\.version), ["1.5.0", "1.4.0", "1.3.0"])
        XCTAssertEqual(Changelog.visible(entries, showingAll: true).map(\.version), entries.map(\.version))
        XCTAssertEqual(Changelog.visible(Array(entries.prefix(2)), showingAll: false).count, 2)
    }
}
