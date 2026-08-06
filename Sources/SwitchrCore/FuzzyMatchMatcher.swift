import FuzzyMatch

/// `Matcher` backed by `ordo-one/FuzzyMatch`.
public struct FuzzyMatchMatcher: Matcher {
    private let matcher = FuzzyMatch.FuzzyMatcher()

    public init() {}

    public func rank(query: String, candidates: [MatchCandidate]) -> [Match] {
        guard !query.isEmpty else {
            return candidates.map { Match(id: $0.id, highlightedRanges: []) }
        }

        let preparedQuery = matcher.prepare(query)
        var buffer = matcher.makeBuffer()

        var scored: [(id: String, primaryText: String, score: Double, matchedPrimary: Bool)] = []
        scored.reserveCapacity(candidates.count)

        for candidate in candidates {
            if let primary = matcher.score(candidate.primaryText, against: preparedQuery, buffer: &buffer) {
                scored.append((candidate.id, candidate.primaryText, primary.score, true))
            } else if let secondaryText = candidate.secondaryText,
                let secondary = matcher.score(secondaryText, against: preparedQuery, buffer: &buffer)
            {
                // Secondary-field matches always rank behind every primary-field
                // match: primary scores are 0...1, so shifting down by 1 keeps
                // this ordering without a second sort key.
                scored.append((candidate.id, candidate.primaryText, secondary.score - 1, false))
            }
        }

        scored.sort { $0.score > $1.score }

        return scored.map { entry in
            let ranges = entry.matchedPrimary
                ? (matcher.highlight(entry.primaryText, against: preparedQuery) ?? [])
                : []
            return Match(id: entry.id, highlightedRanges: ranges)
        }
    }
}
