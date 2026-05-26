import XCTest
@testable import ItsypadCore

final class GlobalSearchTests: XCTestCase {

    private func source(_ name: String, _ content: String, id: UUID = UUID()) -> GlobalSearch.Source {
        GlobalSearch.Source(id: id, name: name, content: content)
    }

    // MARK: - Empty / no results

    func testEmptyQueryReturnsNothing() {
        let results = GlobalSearch.run(query: "", in: [source("A", "hello world")])
        XCTAssertTrue(results.isEmpty)
    }

    func testWhitespaceQueryReturnsNothing() {
        let results = GlobalSearch.run(query: "   ", in: [source("A", "hello world")])
        XCTAssertTrue(results.isEmpty)
    }

    func testNoMatchExcludesTab() {
        let results = GlobalSearch.run(query: "zzz", in: [source("A", "hello world")])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Content matches

    func testSingleContentMatch() {
        let results = GlobalSearch.run(query: "hello", in: [source("A", "hello world")])
        XCTAssertEqual(results.count, 1)
        let match = results[0].matches[0]
        XCTAssertEqual(match.range, NSRange(location: 0, length: 5))
        XCTAssertEqual(match.lineNumber, 1)
        XCTAssertEqual(match.snippet, "hello world")
        XCTAssertEqual(match.highlightRange, NSRange(location: 0, length: 5))
    }

    func testCaseInsensitive() {
        let results = GlobalSearch.run(query: "HELLO", in: [source("A", "say hello there")])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].matches[0].range, NSRange(location: 4, length: 5))
    }

    func testMultipleMatchesAcrossLinesWithLineNumbers() {
        let content = "hello world\nfoo bar\nbaz hello"
        let results = GlobalSearch.run(query: "hello", in: [source("A", content)])
        XCTAssertEqual(results.count, 1)
        let matches = results[0].matches
        XCTAssertEqual(matches.count, 2)

        XCTAssertEqual(matches[0].lineNumber, 1)
        XCTAssertEqual(matches[0].range, NSRange(location: 0, length: 5))

        XCTAssertEqual(matches[1].lineNumber, 3)
        XCTAssertEqual(matches[1].range, NSRange(location: 24, length: 5))
        XCTAssertEqual(matches[1].snippet, "baz hello")
        XCTAssertEqual(matches[1].highlightRange, NSRange(location: 4, length: 5))
    }

    func testLeadingWhitespaceTrimmedAndHighlightAdjusted() {
        let results = GlobalSearch.run(query: "code", in: [source("A", "\t\tlet code = 1")])
        let match = results[0].matches[0]
        XCTAssertEqual(match.snippet, "let code = 1")
        XCTAssertEqual(match.highlightRange, NSRange(location: 4, length: 4))
    }

    func testLongLineTruncatedWithEllipsisAroundMatch() {
        let prefix = String(repeating: "x", count: 200)
        let content = prefix + "NEEDLE" + String(repeating: "y", count: 200)
        let results = GlobalSearch.run(query: "needle", in: [source("A", content)])
        let match = results[0].matches[0]

        XCTAssertTrue(match.snippet.hasPrefix("…"), "expected leading ellipsis")
        XCTAssertTrue(match.snippet.hasSuffix("…"), "expected trailing ellipsis")
        XCTAssertTrue(match.snippet.count <= GlobalSearch.snippetMaxLength + 2)

        // The highlighted slice should be the needle.
        let ns = match.snippet as NSString
        XCTAssertEqual(ns.substring(with: match.highlightRange).lowercased(), "needle")
    }

    func testMatchesCappedPerTab() {
        let content = String(repeating: "a\n", count: GlobalSearch.maxMatchesPerTab + 20)
        let results = GlobalSearch.run(query: "a", in: [source("A", content)])
        XCTAssertEqual(results[0].matches.count, GlobalSearch.maxMatchesPerTab)
    }

    // MARK: - Name matches

    func testNameOnlyMatchYieldsPreview() {
        let results = GlobalSearch.run(query: "notes", in: [source("My notes", "nothing relevant here")])
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].nameMatched)
        let match = results[0].matches[0]
        XCTAssertEqual(match.snippet, "nothing relevant here")
        XCTAssertEqual(match.highlightRange.location, NSNotFound)
        XCTAssertEqual(match.range, NSRange(location: 0, length: 0))
    }

    func testNameAndContentMatchPrefersContentMatches() {
        let results = GlobalSearch.run(query: "todo", in: [source("todo list", "todo: buy milk")])
        XCTAssertTrue(results[0].nameMatched)
        XCTAssertEqual(results[0].matches.count, 1)
        XCTAssertEqual(results[0].matches[0].highlightRange, NSRange(location: 0, length: 4))
    }

    // MARK: - Multiple tabs

    func testResultsPreserveTabOrderAndOnlyIncludeMatches() {
        let a = source("A", "apple")
        let b = source("B", "banana")
        let c = source("C", "cherry apple")
        let results = GlobalSearch.run(query: "apple", in: [a, b, c])
        XCTAssertEqual(results.map(\.tabID), [a.id, c.id])
    }
}
