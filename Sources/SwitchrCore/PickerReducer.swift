/// The picker's state machine: pick an app first, then a window/tab within
/// it, with a global fallthrough search when no app matches.
public struct PickerState: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case selectingApp
        case scoped(RunningApp)
        case globalFallthrough
    }

    public var query: String
    public var stage: Stage
    /// Fixed snapshot for the session — apps don't refresh mid-picker in v0.
    public let availableApps: [AppWithItems]
    /// Tier-0 items for the currently-scoped app, plus anything appended by
    /// a later `.itemsLoaded` (tiers 1-3 arriving lazily).
    public var scopedItems: [PickerItem]
    /// Currently-visible ranked candidate IDs — apps while `.selectingApp`,
    /// items while `.scoped` or `.globalFallthrough`.
    public var rankedIDs: [String]
    public var selectedIndex: Int

    /// `nil` when `selectedIndex` doesn't (or no longer does) point at a
    /// live entry in `rankedIDs` — e.g. nothing ranked yet, or a rerank
    /// shrank the list out from under a stale index.
    var selectedID: String? {
        rankedIDs.indices.contains(selectedIndex) ? rankedIDs[selectedIndex] : nil
    }

    public init(availableApps: [AppWithItems]) {
        self.query = ""
        self.stage = .selectingApp
        self.availableApps = availableApps
        self.scopedItems = []
        self.rankedIDs = availableApps.map(\.app.id)
        self.selectedIndex = 0
    }
}

public enum PickerAction: Equatable, Sendable {
    case queryChanged(String)
    /// Backspace pressed while the (post-commit) query is already empty —
    /// the only way to drop a locked scope. Detected as its own action
    /// because a real text field emits no `queryChanged` when there's
    /// nothing left to delete, and because the locked app-token isn't
    /// reachable by cursor/arrow-key navigation — backspace is the one way
    /// out.
    case backspaceAtStart
    /// Tier 1-3 results arriving asynchronously for the app they were
    /// requested for — tagged so a late arrival can be dropped if the user
    /// has already re-scoped to a different app in the meantime.
    case itemsLoaded([PickerItem], for: RunningApp)
    case moveSelection(by: Int)
    case activateSelection
    /// A scoped hotkey committing straight to stage two, bypassing the
    /// app-token typing entirely — the caller (not the reducer) is
    /// responsible for confirming `app` is actually running first.
    case scopeToApp(RunningApp)
}

/// Work the caller must perform outside the reducer — querying tab/window
/// providers is async and belongs to an adapter, not this pure function.
public enum PickerEffect: Equatable, Sendable {
    case loadItems(for: RunningApp)
}

public enum PickerOutcome: Equatable, Sendable {
    /// Enter at stage one with no scope committed: activate the app itself
    /// (whichever window it last had frontmost), skipping window/tab choice
    /// entirely. The fast exit when you don't need that precision.
    case activateApp(RunningApp)
    case activateItem(PickerItem, in: RunningApp)
}

public enum PickerReducer {
    public static func reduce(
        state: inout PickerState,
        action: PickerAction,
        matcher: Matcher
    ) -> (effect: PickerEffect?, outcome: PickerOutcome?) {
        switch action {
        case .queryChanged(let newQuery):
            let effect = handleQueryChanged(newQuery, state: &state, matcher: matcher)
            return (effect, nil)

        case .backspaceAtStart:
            handleBackspaceAtStart(state: &state, matcher: matcher)
            return (nil, nil)

        case .itemsLoaded(let items, let app):
            handleItemsLoaded(items, for: app, state: &state, matcher: matcher)
            return (nil, nil)

        case .moveSelection(let delta):
            handleMoveSelection(delta, state: &state)
            return (nil, nil)

        case .activateSelection:
            return (nil, handleActivateSelection(state: &state))

        case .scopeToApp(let app):
            let effect = handleScopeToApp(app, state: &state, matcher: matcher)
            return (effect, nil)
        }
    }

    /// A space in the pre-commit text is the one delimiter: everything
    /// before the first space is the app query, everything after becomes the
    /// initial item query. If the app-token matches nothing, the space is
    /// just part of an ordinary (or fallthrough) search string — window/tab
    /// titles routinely contain spaces.
    private static func handleQueryChanged(
        _ newQuery: String,
        state: inout PickerState,
        matcher: Matcher
    ) -> PickerEffect? {
        switch state.stage {
        case .scoped:
            state.query = newQuery
            rerankScoped(&state, matcher: matcher)
            state.selectedIndex = 0
            return nil

        case .selectingApp, .globalFallthrough:
            if let spaceIndex = newQuery.firstIndex(of: " ") {
                let appToken = String(newQuery[..<spaceIndex])
                // Preserve whatever's arrow-key-highlighted across the rerank
                // that follows, so Space and Enter agree on the same
                // selection — falls back to the top hit only if the token
                // itself changed enough to invalidate that selection.
                let previouslySelectedID = state.selectedID

                state.query = appToken
                rerankApps(&state, matcher: matcher)

                let committedID = (previouslySelectedID.flatMap { state.rankedIDs.contains($0) ? $0 : nil })
                    ?? state.rankedIDs.first
                let committedEntry = committedID.flatMap { id in
                    state.availableApps.first(where: { $0.app.id == id })
                }

                if let entry = committedEntry {
                    let itemToken = String(newQuery[newQuery.index(after: spaceIndex)...])
                    state.stage = .scoped(entry.app)
                    state.query = itemToken
                    state.scopedItems = entry.items
                    state.selectedIndex = 0
                    rerankScoped(&state, matcher: matcher)
                    return .loadItems(for: entry.app)
                }
                state.selectedIndex = 0
            }

            state.query = newQuery
            rerankApps(&state, matcher: matcher)
            if !newQuery.isEmpty && state.rankedIDs.isEmpty {
                state.stage = .globalFallthrough
                rerankGlobal(&state, matcher: matcher)
            } else {
                state.stage = .selectingApp
            }
            state.selectedIndex = 0
            return nil
        }
    }

    /// Mirrors the trailing-space commit path in `handleQueryChanged`: seeds
    /// `scopedItems` from the Tier-0 snapshot so the active window/tab has a
    /// selectable row immediately, and still kicks off `.loadItems` for the
    /// Tier 1-3 results Chrome/iTerm's sources omit for that same row.
    private static func handleScopeToApp(
        _ app: RunningApp,
        state: inout PickerState,
        matcher: Matcher
    ) -> PickerEffect? {
        guard let entry = state.availableApps.first(where: { $0.app.id == app.id }) else {
            return nil
        }
        state.stage = .scoped(entry.app)
        state.query = ""
        state.scopedItems = entry.items
        state.selectedIndex = 0
        rerankScoped(&state, matcher: matcher)
        return .loadItems(for: entry.app)
    }

    private static func handleBackspaceAtStart(state: inout PickerState, matcher: Matcher) {
        guard case .scoped = state.stage else { return }
        state.stage = .selectingApp
        state.query = ""
        state.scopedItems = []
        state.selectedIndex = 0
        rerankApps(&state, matcher: matcher)
    }

    private static func handleItemsLoaded(
        _ items: [PickerItem],
        for app: RunningApp,
        state: inout PickerState,
        matcher: Matcher
    ) {
        guard case .scoped(let scopedApp) = state.stage, scopedApp.id == app.id else { return }
        let existingIDs = Set(state.scopedItems.map(\.id))
        state.scopedItems.append(contentsOf: items.filter { !existingIDs.contains($0.id) })

        // Tier 1-3 results can land while the user has already arrow-key'd
        // to an item — preserve that highlight across the rerank rather than
        // silently snapping back to the top hit (same reasoning as the
        // space-commit path above).
        let previouslySelectedID = state.selectedID

        rerankScoped(&state, matcher: matcher)

        if let previouslySelectedID, let newIndex = state.rankedIDs.firstIndex(of: previouslySelectedID) {
            state.selectedIndex = newIndex
        } else {
            state.selectedIndex = 0
        }
    }

    private static func handleMoveSelection(_ delta: Int, state: inout PickerState) {
        guard !state.rankedIDs.isEmpty else { return }
        let count = state.rankedIDs.count
        state.selectedIndex = ((state.selectedIndex + delta) % count + count) % count
    }

    private static func handleActivateSelection(state: inout PickerState) -> PickerOutcome? {
        // Enter with nothing selected does nothing.
        guard let selectedID = state.selectedID else {
            return nil
        }

        switch state.stage {
        case .selectingApp:
            // No scope committed yet: Enter is the fast exit, activating the
            // app without picking a window — space is what gets specific.
            guard let entry = state.availableApps.first(where: { $0.app.id == selectedID }) else {
                return nil
            }
            return .activateApp(entry.app)

        case .scoped(let app):
            guard let item = state.scopedItems.first(where: { $0.id == selectedID }) else {
                return nil
            }
            return .activateItem(item, in: app)

        case .globalFallthrough:
            guard let hit = firstMatch(forItemID: selectedID, in: state.availableApps) else {
                return nil
            }
            return .activateItem(hit.item, in: hit.app)
        }
    }

    private static func firstMatch(
        forItemID id: String,
        in apps: [AppWithItems]
    ) -> (app: RunningApp, item: PickerItem)? {
        for entry in apps {
            if let item = entry.items.first(where: { $0.id == id }) {
                return (entry.app, item)
            }
        }
        return nil
    }

    private static func rerankApps(_ state: inout PickerState, matcher: Matcher) {
        guard !state.query.isEmpty else {
            state.rankedIDs = state.availableApps.map(\.app.id)
            return
        }
        let candidates = state.availableApps.map {
            MatchCandidate(id: $0.app.id, primaryText: $0.app.name)
        }
        state.rankedIDs = matcher.rank(query: state.query, candidates: candidates).map(\.id)
    }

    private static func rerankScoped(_ state: inout PickerState, matcher: Matcher) {
        guard !state.query.isEmpty else {
            state.rankedIDs = state.scopedItems.map(\.id)
            return
        }
        let candidates = state.scopedItems.map {
            MatchCandidate(id: $0.id, primaryText: $0.title, secondaryText: $0.secondaryText)
        }
        state.rankedIDs = matcher.rank(query: state.query, candidates: candidates).map(\.id)
    }

    private static func rerankGlobal(_ state: inout PickerState, matcher: Matcher) {
        let candidates = state.availableApps.flatMap { entry in
            entry.items.map {
                MatchCandidate(id: $0.id, primaryText: $0.title, secondaryText: $0.secondaryText)
            }
        }
        state.rankedIDs = matcher.rank(query: state.query, candidates: candidates).map(\.id)
    }
}
