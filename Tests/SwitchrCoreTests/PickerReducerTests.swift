import Testing
@testable import SwitchrCore

/// Case-insensitive subsequence matcher (query characters appear in order,
/// not necessarily contiguous — "yt" matches "youtube" via y_._._t), scored
/// by how early the match starts so ranking can actually shift between
/// candidates. Reducer tests exercise state-machine transitions, not ranking
/// quality — asserting against FuzzyMatch's exact scores here would just
/// re-test the library and churn on its updates; this only needs to be
/// *directionally* realistic enough to exercise reordering.
private struct StubMatcher: Matcher {
    func rank(query: String, candidates: [MatchCandidate]) -> [Match] {
        guard !query.isEmpty else {
            return candidates.map { Match(id: $0.id, highlightedRanges: []) }
        }
        let needle = query.lowercased()
        let scored: [(id: String, score: Int)] = candidates.compactMap { candidate in
            if let score = subsequenceScore(needle, in: candidate.primaryText.lowercased()) {
                return (candidate.id, score)
            }
            if let secondary = candidate.secondaryText,
                let score = subsequenceScore(needle, in: secondary.lowercased())
            {
                return (candidate.id, score - 1000) // secondary always ranks behind primary
            }
            return nil
        }
        return scored.sorted { $0.score > $1.score }.map { Match(id: $0.id, highlightedRanges: []) }
    }

    /// Higher is better; `nil` means no match. Rewards an earlier first-match position.
    private func subsequenceScore(_ needle: String, in haystack: String) -> Int? {
        var remaining = needle[...]
        var firstMatchIndex: Int?
        for (index, char) in haystack.enumerated() {
            guard let next = remaining.first else { break }
            if char == next {
                if firstMatchIndex == nil { firstMatchIndex = index }
                remaining.removeFirst()
            }
        }
        guard remaining.isEmpty, let firstMatchIndex else { return nil }
        return -firstMatchIndex
    }
}

private let matcher = StubMatcher()

private let chromeApp = RunningApp(id: "com.google.Chrome", name: "Chrome")
private let slackApp = RunningApp(id: "com.tinyspeck.slackmacgap", name: "Slack")
private let finderApp = RunningApp(id: "com.apple.finder", name: "Finder")

private func makeState() -> PickerState {
    let chrome = AppWithItems(
        app: chromeApp,
        items: [
            PickerItem(id: "chrome-1", title: "YouTube - Chill Lofi", secondaryText: "youtube.com"),
            PickerItem(id: "chrome-2", title: "GitHub", secondaryText: "github.com")
        ]
    )
    let slack = AppWithItems(
        app: slackApp,
        items: [
            PickerItem(id: "slack-1", title: "#general")
        ]
    )
    let finder = AppWithItems(
        app: finderApp,
        items: [
            PickerItem(id: "finder-1", title: "Downloads")
        ]
    )
    return PickerState(availableApps: [chrome, slack, finder])
}

@Suite
struct PickerReducerTests {
    @Test
    func typingNarrowsAppsAtStageOne() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("sl"), matcher: matcher)

        #expect(state.stage == .selectingApp)
        #expect(state.rankedIDs == ["com.tinyspeck.slackmacgap"])
    }

    @Test
    func enterAtStageOneActivatesAppDirectlyWithoutCommittingScope() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("ch"), matcher: matcher)
        let (effect, outcome) = PickerReducer.reduce(state: &state, action: .activateSelection, matcher: matcher)

        #expect(state.stage == .selectingApp)
        #expect(effect == nil)
        #expect(outcome == .activateApp(chromeApp))
    }

    @Test
    func trailingSpaceCommitsSelectedAppAndRequestsItemLoad() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("ch"), matcher: matcher)
        let (effect, outcome) = PickerReducer.reduce(state: &state, action: .queryChanged("ch "), matcher: matcher)

        #expect(state.stage == .scoped(chromeApp))
        #expect(state.query == "")
        #expect(Set(state.scopedItems.map(\.id)) == ["chrome-1", "chrome-2"])
        #expect(effect == .loadItems(for: chromeApp))
        #expect(outcome == nil)
    }

    @Test
    func spaceCommitsArrowKeySelectedAppNotJustTopHit() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("c"), matcher: matcher)
        #expect(state.rankedIDs == ["com.google.Chrome", "com.tinyspeck.slackmacgap"])

        _ = PickerReducer.reduce(state: &state, action: .moveSelection(by: 1), matcher: matcher)
        #expect(state.selectedIndex == 1)

        // Enter, from this same highlighted state, would activate Slack --
        // Space (drilling in instead of exiting) must agree, not silently
        // fall back to the top-ranked Chrome.
        let (effect, _) = PickerReducer.reduce(state: &state, action: .queryChanged("c "), matcher: matcher)

        #expect(state.stage == .scoped(slackApp))
        #expect(effect == .loadItems(for: slackApp))
    }

    @Test
    func pastingFullSpaceDelimitedQueryCommitsAndSeedsItemToken() {
        var state = makeState()
        let (effect, _) = PickerReducer.reduce(state: &state, action: .queryChanged("ch yt"), matcher: matcher)

        #expect(state.stage == .scoped(chromeApp))
        #expect(state.query == "yt")
        #expect(state.rankedIDs == ["chrome-1"])
        #expect(effect == .loadItems(for: chromeApp))
    }

    @Test
    func spaceWithNoMatchingAppTokenIsTreatedAsLiteralFallthroughText() {
        var state = makeState()
        let (effect, _) = PickerReducer.reduce(state: &state, action: .queryChanged("chill lofi"), matcher: matcher)

        #expect(state.stage == .globalFallthrough)
        #expect(state.rankedIDs == ["chrome-1"])
        #expect(effect == nil)
    }

    @Test
    func enterWithNothingSelectedDoesNothing() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("zzz-no-match"), matcher: matcher)
        #expect(state.stage == .globalFallthrough)

        // Clear rankedIDs to simulate a query with no candidates at all.
        state.rankedIDs = []
        let (effect, outcome) = PickerReducer.reduce(state: &state, action: .activateSelection, matcher: matcher)

        #expect(effect == nil)
        #expect(outcome == nil)
    }

    @Test
    func backspaceAtStartDropsScopeBackToStageOne() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("ch "), matcher: matcher)
        #expect(state.stage == .scoped(chromeApp))

        _ = PickerReducer.reduce(state: &state, action: .backspaceAtStart, matcher: matcher)

        #expect(state.stage == .selectingApp)
        #expect(state.query == "")
        #expect(state.scopedItems.isEmpty)
        #expect(state.rankedIDs == ["com.google.Chrome", "com.tinyspeck.slackmacgap", "com.apple.finder"])
    }

    @Test
    func backspaceAtStartIsNoOpOutsideScopedStage() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("sl"), matcher: matcher)

        _ = PickerReducer.reduce(state: &state, action: .backspaceAtStart, matcher: matcher)

        #expect(state.stage == .selectingApp)
        #expect(state.query == "sl")
    }

    @Test
    func fallsThroughToGlobalSearchWhenNoAppMatches() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("lofi"), matcher: matcher)

        #expect(state.stage == .globalFallthrough)
        #expect(state.rankedIDs == ["chrome-1"])
    }

    @Test
    func fallthroughRevertsToStageOneWhenAppMatchesAgain() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("lofi"), matcher: matcher)
        #expect(state.stage == .globalFallthrough)

        _ = PickerReducer.reduce(state: &state, action: .queryChanged("sl"), matcher: matcher)

        #expect(state.stage == .selectingApp)
        #expect(state.rankedIDs == ["com.tinyspeck.slackmacgap"])
    }

    @Test
    func activatingInScopedStageProducesOutcome() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("sl "), matcher: matcher)
        #expect(state.stage == .scoped(slackApp))

        let (effect, outcome) = PickerReducer.reduce(state: &state, action: .activateSelection, matcher: matcher)

        #expect(effect == nil)
        #expect(outcome == .activateItem(PickerItem(id: "slack-1", title: "#general"), in: slackApp))
    }

    @Test
    func activatingInGlobalFallthroughResolvesCorrectApp() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("lofi"), matcher: matcher)
        #expect(state.stage == .globalFallthrough)

        let (effect, outcome) = PickerReducer.reduce(state: &state, action: .activateSelection, matcher: matcher)

        #expect(effect == nil)
        #expect(outcome == .activateItem(
            PickerItem(id: "chrome-1", title: "YouTube - Chill Lofi", secondaryText: "youtube.com"),
            in: chromeApp
        ))
    }

    @Test
    func itemsLoadedAppendsWithoutDuplicatesAndReranks() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("ch "), matcher: matcher)

        let newTab = PickerItem(id: "chrome-3", title: "Inbox - Gmail")
        let duplicate = PickerItem(id: "chrome-1", title: "YouTube - Chill Lofi (stale title)")
        _ = PickerReducer.reduce(state: &state, action: .itemsLoaded([newTab, duplicate]), matcher: matcher)

        #expect(state.scopedItems.count == 3)
        #expect(state.scopedItems.first(where: { $0.id == "chrome-1" })?.title == "YouTube - Chill Lofi")
    }

    @Test
    func itemsLoadedPreservesHighlightedItemAcrossReorder() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("ch "), matcher: matcher)
        // "i" ranks GitHub (i at index 1) above YouTube... (i at index 12).
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("i"), matcher: matcher)
        #expect(state.rankedIDs == ["chrome-2", "chrome-1"])

        _ = PickerReducer.reduce(state: &state, action: .moveSelection(by: 1), matcher: matcher)
        #expect(state.rankedIDs[state.selectedIndex] == "chrome-1")

        // A newly-arrived tab ("Gmail", i at index 3) scores between the two
        // existing items, inserting ahead of the highlighted one.
        let newTab = PickerItem(id: "chrome-3", title: "Gmail")
        _ = PickerReducer.reduce(state: &state, action: .itemsLoaded([newTab]), matcher: matcher)

        #expect(state.rankedIDs == ["chrome-2", "chrome-3", "chrome-1"])
        #expect(state.rankedIDs[state.selectedIndex] == "chrome-1")
    }

    @Test
    func itemsLoadedIsNoOpOutsideScopedStage() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .itemsLoaded([PickerItem(id: "x", title: "x")]), matcher: matcher)
        #expect(state.scopedItems.isEmpty)
    }

    @Test
    func moveSelectionWrapsAround() {
        var state = makeState()
        #expect(state.rankedIDs.count == 3)

        _ = PickerReducer.reduce(state: &state, action: .moveSelection(by: -1), matcher: matcher)
        #expect(state.selectedIndex == 2)

        _ = PickerReducer.reduce(state: &state, action: .moveSelection(by: 1), matcher: matcher)
        #expect(state.selectedIndex == 0)
    }

    @Test
    func scopeToAppEntersScopedStageDirectlyLikeSpaceCommit() {
        var state = makeState()
        let (effect, outcome) = PickerReducer.reduce(state: &state, action: .scopeToApp(chromeApp), matcher: matcher)

        #expect(state.stage == .scoped(chromeApp))
        #expect(state.query == "")
        #expect(Set(state.scopedItems.map(\.id)) == ["chrome-1", "chrome-2"])
        #expect(state.rankedIDs == ["chrome-1", "chrome-2"])
        #expect(effect == .loadItems(for: chromeApp))
        #expect(outcome == nil)
    }

    @Test
    func scopeToAppSelectionIsImmediatelyActivatable() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .scopeToApp(chromeApp), matcher: matcher)

        let (_, outcome) = PickerReducer.reduce(state: &state, action: .activateSelection, matcher: matcher)

        #expect(outcome == .activateItem(
            PickerItem(id: "chrome-1", title: "YouTube - Chill Lofi", secondaryText: "youtube.com"),
            in: chromeApp
        ))
    }

    @Test
    func scopeToAppForUnknownAppIsNoOp() {
        var state = makeState()
        let unknownApp = RunningApp(id: "com.example.unknown", name: "Unknown")
        let (effect, outcome) = PickerReducer.reduce(state: &state, action: .scopeToApp(unknownApp), matcher: matcher)

        #expect(state.stage == .selectingApp)
        #expect(effect == nil)
        #expect(outcome == nil)
    }

    @Test
    func emptyQueryClearingFallthroughResetsToFullAppList() {
        var state = makeState()
        _ = PickerReducer.reduce(state: &state, action: .queryChanged("lofi"), matcher: matcher)
        #expect(state.stage == .globalFallthrough)

        _ = PickerReducer.reduce(state: &state, action: .queryChanged(""), matcher: matcher)

        #expect(state.stage == .selectingApp)
        #expect(state.rankedIDs == ["com.google.Chrome", "com.tinyspeck.slackmacgap", "com.apple.finder"])
    }
}
