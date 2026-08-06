/// One item to rank against a query: a primary matched-and-displayed field,
/// and an optional lower-weighted secondary field that's matched but not
/// necessarily shown (a browser tab's URL, for example).
public struct MatchCandidate: Equatable, Sendable {
    public let id: String
    public let primaryText: String
    public let secondaryText: String?

    public init(id: String, primaryText: String, secondaryText: String? = nil) {
        self.id = id
        self.primaryText = primaryText
        self.secondaryText = secondaryText
    }
}

public struct Match: Equatable, Sendable {
    public let id: String
    /// Ranges into the corresponding candidate's `primaryText`, for highlighting.
    /// Empty when the match came from `secondaryText` (nothing to highlight in
    /// what isn't displayed) or when the query is empty.
    public let highlightedRanges: [Range<String.Index>]

    public init(id: String, highlightedRanges: [Range<String.Index>]) {
        self.id = id
        self.highlightedRanges = highlightedRanges
    }
}

/// Scores and ranks candidates against a query. Behind a protocol so the
/// implementation is a one-line swap.
public protocol Matcher: Sendable {
    /// Ranks `candidates` against `query`, best match first. Candidates with
    /// no match (against either field) are omitted. An empty query is treated
    /// as "everything matches", preserving input order.
    func rank(query: String, candidates: [MatchCandidate]) -> [Match]
}
