import Testing
@testable import SwitchrCore

/// Smoke tests only — this is a thin wrapper over `ordo-one/FuzzyMatch`.
/// Asserting its exact rank order here would just re-test the library and
/// churn on every update; these confirm the protocol conformance is wired
/// correctly (matches surface, highlights land on the primary field,
/// non-matches are dropped, secondary-field matches rank last).
@Suite
struct FuzzyMatchMatcherTests {
    private let matcher = FuzzyMatchMatcher()

    @Test
    func matchingCandidateIsReturnedWithHighlights() {
        let candidates = [MatchCandidate(id: "1", primaryText: "Chrome")]
        let results = matcher.rank(query: "chr", candidates: candidates)

        #expect(results.map(\.id) == ["1"])
        #expect(!results[0].highlightedRanges.isEmpty)
    }

    @Test
    func nonMatchingCandidateIsOmitted() {
        let candidates = [MatchCandidate(id: "1", primaryText: "Chrome")]
        let results = matcher.rank(query: "zzzzzz", candidates: candidates)

        #expect(results.isEmpty)
    }

    @Test
    func secondaryFieldMatchRanksBehindPrimaryFieldMatch() {
        let candidates = [
            MatchCandidate(id: "url-only", primaryText: "Untitled", secondaryText: "example.com/chrome"),
            MatchCandidate(id: "title-match", primaryText: "Chrome release notes")
        ]
        let results = matcher.rank(query: "chrome", candidates: candidates)

        #expect(results.map(\.id) == ["title-match", "url-only"])
        #expect(results[1].highlightedRanges.isEmpty)
    }

    @Test
    func emptyQueryReturnsAllCandidatesInOrderWithNoHighlights() {
        let candidates = [
            MatchCandidate(id: "1", primaryText: "Chrome"),
            MatchCandidate(id: "2", primaryText: "Slack")
        ]
        let results = matcher.rank(query: "", candidates: candidates)

        #expect(results.map(\.id) == ["1", "2"])
        #expect(results.allSatisfy { $0.highlightedRanges.isEmpty })
    }
}
