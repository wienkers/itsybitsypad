import Foundation

/// Lightweight, testable statistics for a tab's content.
struct TabStats: Equatable {
    let words: Int
    let charactersWithSpaces: Int
    let charactersWithoutSpaces: Int
    let sentences: Int
    let paragraphs: Int
    let lines: Int
    /// Estimated reading time in whole seconds.
    let readingSeconds: Int

    static let wordsPerMinute = 200

    static func compute(content: String) -> TabStats {
        let charactersWithSpaces = content.count
        let charactersWithoutSpaces = content.filter { !$0.isWhitespace }.count
        let words = content.split(whereSeparator: { $0.isWhitespace }).count
        let lines = content.isEmpty ? 0 : content.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
        let paragraphs = content
            .split(whereSeparator: { $0.isNewline })
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .count

        var sentences = 0
        content.enumerateSubstrings(in: content.startIndex..<content.endIndex, options: .bySentences) { substring, _, _, _ in
            if let substring, !substring.allSatisfy(\.isWhitespace) { sentences += 1 }
        }

        let readingSeconds = Int((Double(words) / Double(wordsPerMinute) * 60).rounded())

        return TabStats(
            words: words,
            charactersWithSpaces: charactersWithSpaces,
            charactersWithoutSpaces: charactersWithoutSpaces,
            sentences: sentences,
            paragraphs: paragraphs,
            lines: lines,
            readingSeconds: readingSeconds
        )
    }

    /// Reading time formatted as "Xm Ys".
    var readingTimeText: String {
        "\(readingSeconds / 60)m \(readingSeconds % 60)s"
    }

    /// Maps a highlight.js language id to a human-readable format name.
    static func displayName(forLanguage id: String) -> String {
        languageNames[id] ?? id.capitalized
    }

    private static let languageNames: [String: String] = [
        "plain": "Plain text",
        "markdown": "Markdown",
        "javascript": "JavaScript",
        "typescript": "TypeScript",
        "python": "Python",
        "swift": "Swift",
        "java": "Java",
        "kotlin": "Kotlin",
        "c": "C",
        "cpp": "C++",
        "csharp": "C#",
        "objectivec": "Objective-C",
        "go": "Go",
        "rust": "Rust",
        "ruby": "Ruby",
        "php": "PHP",
        "css": "CSS",
        "scss": "SCSS",
        "html": "HTML",
        "xml": "XML",
        "json": "JSON",
        "yaml": "YAML",
        "toml": "TOML",
        "ini": "INI",
        "sql": "SQL",
        "bash": "Shell",
        "shell": "Shell",
    ]
}
