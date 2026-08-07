import Cocoa
import SwitchrCore

/// Mediates between the (dumb) `PickerPanel` view and the pure
/// `PickerReducer`: turns panel delegate callbacks into `PickerAction`s,
/// renders the resulting `rankedIDs` back as titles, and performs the
/// effects/outcomes the reducer can't do itself (querying `WindowSource`,
/// activating an app or window).
@MainActor
final class PickerController: PickerPanelDelegate {
    private let panel = PickerPanel()
    private let appSource: AXAppSource
    private let chromeSource = ChromeWindowSource()
    private let itermSource = ITermWindowSource()
    private let genericSource: WindowSource = AXTabWindowSource()
    private let matcher: Matcher = FuzzyMatchMatcher()
    private var state: PickerState?

    init(appSource: AXAppSource) {
        self.appSource = appSource
        panel.pickerDelegate = self
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible {
            dismiss()
        } else {
            present()
        }
    }

    private func present() {
        panel.showCentered()
        panel.setResults(titles: [], selectedIndex: 0)
        Task { [weak self] in
            guard let self else { return }
            let apps = await self.appSource.runningApps()
            self.state = PickerState(availableApps: apps)
            self.pushResults()
        }
    }

    private func dismiss() {
        panel.hidePanel()
        state = nil
    }

    private func pushResults() {
        guard let state else {
            panel.setResults(titles: [], selectedIndex: 0)
            panel.setScope(nil)
            return
        }
        panel.setResults(titles: displayTitles(for: state), selectedIndex: state.selectedIndex)
        panel.setScope(scopedAppName(for: state))
        panel.setQueryText(state.query)
    }

    private func scopedAppName(for state: PickerState) -> String? {
        guard case .scoped(let app) = state.stage else { return nil }
        return app.name
    }

    private func displayTitles(for state: PickerState) -> [String] {
        switch state.stage {
        case .selectingApp:
            return state.rankedIDs.compactMap { id in
                state.availableApps.first { $0.app.id == id }?.app.name
            }
        case .scoped:
            return state.rankedIDs.compactMap { id in
                state.scopedItems.first { $0.id == id }?.title
            }
        case .globalFallthrough:
            return state.rankedIDs.compactMap { id in
                state.availableApps.lazy.flatMap(\.items).first { $0.id == id }?.title
            }
        }
    }

    private func send(_ action: PickerAction) {
        guard var state else { return }
        let (effect, outcome) = PickerReducer.reduce(state: &state, action: action, matcher: matcher)
        self.state = state
        pushResults()

        if let effect { handle(effect) }
        if let outcome { handle(outcome) }
    }

    /// Chrome and iTerm2 get their Apple Events sources; everything else
    /// falls through to the generic AX tab-group walker.
    private func windowSource(for app: RunningApp) -> WindowSource {
        switch app.id {
        case ChromeWindowSource.bundleID: return chromeSource
        case ITermWindowSource.bundleID: return itermSource
        default: return genericSource
        }
    }

    private func handle(_ effect: PickerEffect) {
        switch effect {
        case .loadItems(let app):
            Task { [weak self] in
                guard let self else { return }
                let items = await self.windowSource(for: app).items(for: app)
                guard !items.isEmpty else { return }
                self.send(.itemsLoaded(items))
            }
        }
    }

    private func handle(_ outcome: PickerOutcome) {
        switch outcome {
        case .activateApp(let app):
            appSource.activate(app: app)
        case .activateItem(let item, let app):
            activate(item: item, in: app)
        }
        dismiss()
    }

    /// Dispatches by the item id's own shape rather than `app.id`: a scoped
    /// app's item list is mixed-provenance (Tier-0 AX window rows alongside
    /// Tier-1 Apple Events rows), since Chrome/iTerm sources deliberately
    /// omit the active tab/session and leave its row to Tier-0. Each
    /// activator recognizes only its own id shape and returns `false`
    /// immediately otherwise, so trying them in sequence costs nothing extra
    /// for ids it doesn't own.
    private func activate(item: PickerItem, in app: RunningApp) {
        Task { [chromeSource, itermSource, appSource] in
            if await chromeSource.activate(item: item) { return }
            if await itermSource.activate(item: item) { return }
            appSource.activate(item: item, in: app)
        }
    }

    // MARK: - PickerPanelDelegate

    func pickerPanel(_ panel: PickerPanel, queryChanged query: String) {
        send(.queryChanged(query))
    }

    func pickerPanelBackspaceAtStart(_ panel: PickerPanel) {
        send(.backspaceAtStart)
    }

    func pickerPanel(_ panel: PickerPanel, moveSelectionBy delta: Int) {
        send(.moveSelection(by: delta))
    }

    func pickerPanelActivateSelection(_ panel: PickerPanel) {
        send(.activateSelection)
    }

    func pickerPanelCancel(_ panel: PickerPanel) {
        dismiss()
    }
}
