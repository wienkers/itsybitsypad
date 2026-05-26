import Foundation

/// A single match within a tab's content (or a name-only match preview).
struct GlobalSearchMatch: Equatable {
    /// Range of the match in the tab's full content, used to reveal/select it.
    let range: NSRange
    /// 1-based line number of the match.
    let lineNumber: Int
    /// Display line, possibly truncated with leading/trailing ellipses.
    let snippet: String
    /// Range of the query within `snippet` (NSString domain).
    /// `location == NSNotFound` when there is nothing to highlight (name-only match).
    let highlightRange: NSRange
}

/// All matches for one tab.
struct GlobalSearchTabResult: Equatable {
    let tabID: UUID
    let tabName: String
    /// Whether the query matched the tab's name.
    let nameMatched: Bool
    let matches: [GlobalSearchMatch]
}

/// Searches across all open tabs' content and names. Pure logic, no UI.
enum GlobalSearch {
    static let maxMatchesPerTab = 50
    static let snippetMaxLength = 120
    static let snippetContextBefore = 24

    /// A searchable tab, decoupled from TabData for testability.
    struct Source {
        let id: UUID
        let name: String
        let content: String
    }

    static func run(query rawQuery: String, in sources: [Source]) -> [GlobalSearchTabResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var results: [GlobalSearchTabResult] = []
        for source in sources {
            let nameMatched = source.name.localizedCaseInsensitiveContains(query)
            var matches = contentMatches(query: query, content: source.content)
            if matches.isEmpty {
                guard nameMatched else { continue }
                matches = [nameOnlyMatch(content: source.content)]
            }
            results.append(GlobalSearchTabResult(
                tabID: source.id,
                tabName: source.name,
                nameMatched: nameMatched,
                matches: matches
            ))
        }
        return results
    }

    // MARK: - Content scan

    private static func contentMatches(query: String, content: String) -> [GlobalSearchMatch] {
        let ns = content as NSString
        guard ns.length > 0 else { return [] }

        var matches: [GlobalSearchMatch] = []
        var searchStart = 0
        // Track line number incrementally so the whole scan stays O(n + matches).
        var scannedTo = 0
        var lineAtScanned = 1

        while searchStart < ns.length {
            let searchRange = NSRange(location: searchStart, length: ns.length - searchStart)
            let found = ns.range(of: query, options: [.caseInsensitive], range: searchRange)
            if found.location == NSNotFound { break }

            while scannedTo < found.location {
                if ns.character(at: scannedTo) == 10 { lineAtScanned += 1 } // \n
                scannedTo += 1
            }

            let snippet = makeSnippet(ns: ns, matchRange: found)
            matches.append(GlobalSearchMatch(
                range: found,
                lineNumber: lineAtScanned,
                snippet: snippet.text,
                highlightRange: snippet.highlight
            ))
            if matches.count >= maxMatchesPerTab { break }
            searchStart = found.location + max(found.length, 1)
        }
        return matches
    }

    /// Builds a trimmed, truncated snippet around a match and the highlight range within it.
    private static func makeSnippet(ns: NSString, matchRange: NSRange) -> (text: String, highlight: NSRange) {
        let lineRange = ns.lineRange(for: matchRange)
        var line = ns.substring(with: lineRange) as NSString
        // Strip trailing line breaks.
        var end = line.length
        while end > 0 {
            let c = line.character(at: end - 1)
            if c == 10 || c == 13 { end -= 1 } else { break }
        }
        if end != line.length { line = line.substring(to: end) as NSString }

        var matchInLine = matchRange.location - lineRange.location

        // Trim leading whitespace.
        var leading = 0
        while leading < line.length {
            let c = line.character(at: leading)
            if c == 32 || c == 9 { leading += 1 } else { break }
        }
        if leading > 0 {
            line = line.substring(from: leading) as NSString
            matchInLine = max(0, matchInLine - leading)
        }

        guard line.length > snippetMaxLength else {
            let highlight = clampRange(NSRange(location: matchInLine, length: matchRange.length), within: line.length)
            return (line as String, highlight)
        }

        // Window around the match for long lines.
        let start = max(0, matchInLine - snippetContextBefore)
        let windowEnd = min(line.length, start + snippetMaxLength)
        var sub = line.substring(with: NSRange(location: start, length: windowEnd - start))
        var highlightLoc = matchInLine - start

        if start > 0 {
            sub = "…" + sub
            highlightLoc += 1
        }
        if windowEnd < line.length {
            sub += "…"
        }

        let highlight = clampRange(NSRange(location: highlightLoc, length: matchRange.length), within: (sub as NSString).length)
        return (sub, highlight)
    }

    /// For tabs that match only by name: show a preview of the first non-empty line.
    private static func nameOnlyMatch(content: String) -> GlobalSearchMatch {
        let ns = content as NSString
        var preview = ""
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, _, _, stop in
            let trimmed = (line ?? "").trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                preview = trimmed.count > snippetMaxLength ? String(trimmed.prefix(snippetMaxLength)) + "…" : trimmed
                stop.pointee = true
            }
        }
        return GlobalSearchMatch(
            range: NSRange(location: 0, length: 0),
            lineNumber: 1,
            snippet: preview,
            highlightRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private static func clampRange(_ range: NSRange, within length: Int) -> NSRange {
        guard range.location != NSNotFound, range.location <= length else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let len = min(range.length, length - range.location)
        return NSRange(location: range.location, length: max(0, len))
    }
}
