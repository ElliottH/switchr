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
    private let windowSource: WindowSource = AXTabWindowSource()
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

    private func handle(_ effect: PickerEffect) {
        switch effect {
        case .loadItems(let app):
            Task { [weak self] in
                guard let self else { return }
                let items = await self.windowSource.items(for: app)
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
            appSource.activate(item: item, in: app)
        }
        dismiss()
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
