import Cocoa
import SwitchrCore

/// What a fired hotkey chord is bound to — the same shape as
/// `HotkeyBinding.Scope`. `.apps` is resolved at press time to whichever
/// listed bundle ID is actually running (first match in list order); a
/// single physical chord can only ever target one app per press, so this
/// stays one `RegisteredHotkey` per config entry rather than one per bundle
/// ID, which would leave multiple registrations racing for the same chord.
enum HotkeyScope: Equatable {
    case global
    case apps([String])
}

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
    /// Whether the current scoped-hotkey hold has actually cycled the
    /// selection yet. A quick tap-and-release opens the picker and leaves it
    /// open for typing, same as before scoped hotkeys existed — only once
    /// the chord fires a *second* time while already scoped does a held
    /// session start, and only then does releasing the modifier commit.
    /// Without this, a plain quick tap (press+release close enough together
    /// that the modifier's release always follows) would commit the
    /// top-ranked item immediately and never leave the picker open at all.
    private var isHotkeyHeldSession = false

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

    /// A hotkey chord firing. For `.global` this is just the existing
    /// toggle. For `.app`, the doc's "hold modifier, tap to cycle" behaviour
    /// means a *repeat* press while already scoped to that same app advances
    /// the selection instead of re-presenting from scratch.
    func hotkeyPressed(scope: HotkeyScope) {
        switch scope {
        case .global:
            toggle()
        case .apps(let bundleIDs):
            if panel.isVisible, case .scoped(let app) = state?.stage, bundleIDs.contains(app.id) {
                isHotkeyHeldSession = true
                send(.moveSelection(by: 1))
            } else {
                isHotkeyHeldSession = false
                presentScoped(bundleIDs: bundleIDs)
            }
        }
    }

    /// The chord's modifiers being released — commits whatever's currently
    /// selected, same as pressing Enter, but only if this hold actually
    /// cycled the selection. A release that follows nothing but the
    /// opening press is a no-op, leaving the picker open for typing.
    func hotkeyReleased(scope: HotkeyScope) {
        guard case .apps = scope, isHotkeyHeldSession, panel.isVisible, case .scoped = state?.stage else { return }
        isHotkeyHeldSession = false
        send(.activateSelection)
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

    /// Scoped-hotkey entry point: jumps straight to stage two, skipping the
    /// app-token typing. `bundleIDs` is checked in list order for the first
    /// one actually running; if none are, the first one is launched instead
    /// — the design doc scopes launch-on-miss to the hotkey path only, not
    /// the picker's Enter key.
    private func presentScoped(bundleIDs: [String]) {
        let running = NSWorkspace.shared.runningApplications
        guard let targetBundleID = bundleIDs.first(where: { id in running.contains { $0.bundleIdentifier == id } })
        else {
            if let fallback = bundleIDs.first { launchApp(bundleID: fallback) }
            dismiss()
            return
        }

        // Chrome/iTerm always show the picker immediately, then fill in
        // Tier-1 tabs async — unchanged, since that's the whole point of
        // having a rich provider for them. Everything else's final item
        // count is knowable up front from a single cheap in-process AX
        // call, so it's worth the brief wait to decide first: a single
        // window with no native tabs of its own was never going to become
        // more than one candidate, and showing a one-row picker just to
        // make the user confirm a choice that isn't one is the papercut
        // this skips.
        let hasTabProvider = targetBundleID == ChromeWindowSource.bundleID || targetBundleID == ITermWindowSource.bundleID
        if hasTabProvider {
            panel.showCentered()
            panel.setResults(titles: [], selectedIndex: 0)
        }

        Task { [weak self] in
            guard let self else { return }
            let apps = await self.appSource.runningApps()
            guard let entry = apps.first(where: { $0.app.id == targetBundleID }) else {
                self.dismiss()
                return
            }

            if !hasTabProvider, entry.items.count == 1 {
                let tabs = await self.genericSource.items(for: entry.app)
                if tabs.isEmpty {
                    self.appSource.activate(item: entry.items[0], in: entry.app)
                    self.dismiss()
                    return
                }
            }

            if !self.panel.isVisible {
                self.panel.showCentered()
                self.panel.setResults(titles: [], selectedIndex: 0)
            }
            self.state = PickerState(availableApps: apps)
            self.send(.scopeToApp(entry.app))
        }
    }

    private func launchApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
                self.send(.itemsLoaded(items, for: app))
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
