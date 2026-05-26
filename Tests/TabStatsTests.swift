import XCTest
@testable import ItsypadCore

final class TabStatsTests: XCTestCase {

    func testEmptyContent() {
        let s = TabStats.compute(content: "")
        XCTAssertEqual(s.words, 0)
        XCTAssertEqual(s.charactersWithSpaces, 0)
        XCTAssertEqual(s.charactersWithoutSpaces, 0)
        XCTAssertEqual(s.sentences, 0)
        XCTAssertEqual(s.paragraphs, 0)
        XCTAssertEqual(s.lines, 0)
        XCTAssertEqual(s.readingSeconds, 0)
    }

    func testSingleLine() {
        let s = TabStats.compute(content: "the quick brown fox")
        XCTAssertEqual(s.words, 4)
        XCTAssertEqual(s.charactersWithSpaces, 19)
        XCTAssertEqual(s.charactersWithoutSpaces, 16)
        XCTAssertEqual(s.lines, 1)
        XCTAssertEqual(s.paragraphs, 1)
    }

    func testCharactersWithAndWithoutSpaces() {
        let s = TabStats.compute(content: "a b  c\td\ne")
        XCTAssertEqual(s.charactersWithSpaces, 10) // includes spaces, tab, newline
        XCTAssertEqual(s.charactersWithoutSpaces, 5) // a b c d e
    }

    func testCollapsesRepeatedWhitespace() {
        let s = TabStats.compute(content: "a   b\t\tc\n\nd")
        XCTAssertEqual(s.words, 4)
    }

    func testCharactersCountGraphemes() {
        let s = TabStats.compute(content: "a😀b")
        XCTAssertEqual(s.charactersWithSpaces, 3)
    }

    func testLinesCountIncludesTrailingEmptyLine() {
        let s = TabStats.compute(content: "hello world\nfoo bar baz\n")
        XCTAssertEqual(s.words, 5)
        XCTAssertEqual(s.lines, 3)
    }

    func testParagraphsIgnoreBlankLines() {
        let s = TabStats.compute(content: "para one\n\npara two\n\n\npara three")
        XCTAssertEqual(s.paragraphs, 3)
    }

    func testSentences() {
        let s = TabStats.compute(content: "Hello world. How are you? I'm fine!")
        XCTAssertEqual(s.sentences, 3)
    }

    // MARK: - Reading time

    func testReadingSecondsForShortText() {
        // 4 words at 200 wpm -> 1.2s -> 1s.
        let s = TabStats.compute(content: "the quick brown fox")
        XCTAssertEqual(s.readingSeconds, 1)
        XCTAssertEqual(s.readingTimeText, "0m 1s")
    }

    func testReadingTimeTextMinutesAndSeconds() {
        // 250 words at 200 wpm -> 75s -> "1m 15s".
        let content = Array(repeating: "word", count: 250).joined(separator: " ")
        let s = TabStats.compute(content: content)
        XCTAssertEqual(s.readingSeconds, 75)
        XCTAssertEqual(s.readingTimeText, "1m 15s")
    }

    // MARK: - Language display names

    func testKnownLanguageDisplayNames() {
        XCTAssertEqual(TabStats.displayName(forLanguage: "plain"), "Plain text")
        XCTAssertEqual(TabStats.displayName(forLanguage: "markdown"), "Markdown")
        XCTAssertEqual(TabStats.displayName(forLanguage: "cpp"), "C++")
        XCTAssertEqual(TabStats.displayName(forLanguage: "json"), "JSON")
    }

    func testUnknownLanguageFallsBackToCapitalized() {
        XCTAssertEqual(TabStats.displayName(forLanguage: "haskell"), "Haskell")
    }
}
