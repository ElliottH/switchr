import ApplicationServices
import Cocoa
import SwitchrCore

/// Tier-0 discovery: running regular-activation-policy apps, each with its AX
/// windows. `PickerItem.id` encodes `"pid:windowIndex"` rather than caching
/// an `AXUIElement` handle, so nothing here needs to cross an actor or task
/// boundary except plain value types — activation re-fetches the window list
/// for the one app the user picked, which is cheap and avoids ever holding a
/// stale AX reference.
///
/// Isolated to the main actor so the mutable MRU list is only ever touched
/// from one place. Per-app AX enumeration itself still happens off-main, in
/// parallel, inside the `nonisolated` `discoverWindows` — discovery fires
/// from the tap-callback path, and a synchronous AX hang must never risk the
/// tap's own timeout on main.
@MainActor
final class AXAppSource: AppSource {
    private var mruBundleIDs: [String] = []
    private var activationObserver: NSObjectProtocol?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleID = app.bundleIdentifier
            else { return }
            Task { @MainActor in
                self.mruBundleIDs.removeAll { $0 == bundleID }
                self.mruBundleIDs.insert(bundleID, at: 0)
            }
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func runningApps() async -> [AppWithItems] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID }
            .map { (pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: $0.localizedName) }

        let discovered = await withTaskGroup(
            of: (pid: pid_t, bundleID: String?, name: String?, items: [PickerItem]).self
        ) { group in
            for candidate in candidates {
                group.addTask {
                    let items = await Self.discoverWindows(pid: candidate.pid)
                    return (candidate.pid, candidate.bundleID, candidate.name, items)
                }
            }
            var results: [(pid: pid_t, bundleID: String?, name: String?, items: [PickerItem])] = []
            for await result in group { results.append(result) }
            return results
        }

        let withItems = discovered.filter { !$0.items.isEmpty }
        // Stable sort preserves NSWorkspace's own order as the tiebreak for
        // apps the MRU list doesn't (yet) mention.
        let ranked = withItems.sorted { lhs, rhs in
            let lhsRank = mruBundleIDs.firstIndex(of: lhs.bundleID ?? "") ?? Int.max
            let rhsRank = mruBundleIDs.firstIndex(of: rhs.bundleID ?? "") ?? Int.max
            return lhsRank < rhsRank
        }

        return ranked.map { entry in
            AppWithItems(
                app: RunningApp(id: entry.bundleID ?? String(entry.pid), name: entry.name ?? "Unknown"),
                items: entry.items
            )
        }
    }

    /// Raises `app`'s frontmost window without picking a specific one.
    func activate(app: RunningApp) {
        guard let pid = resolvePID(forAppID: app.id) else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// Raises the specific window (and, for a Tier-2 tab item, presses the
    /// specific tab) backing `item`, unminimising first if needed —
    /// activation is more than `AXRaise`.
    func activate(item: PickerItem, in app: RunningApp) {
        guard
            let pid = resolvePID(forAppID: app.id),
            let target = Self.parseItemID(item.id)
        else {
            activate(app: app)
            return
        }

        switch target {
        case .window(let windowPID, let windowIndex):
            guard windowPID == pid, let window = Self.window(forPID: pid, index: windowIndex) else {
                activate(app: app)
                return
            }
            Self.raise(window: window, pid: pid)

        case .tab(let windowPID, let windowIndex, let tabIndex):
            guard windowPID == pid, let window = Self.window(forPID: pid, index: windowIndex) else {
                activate(app: app)
                return
            }
            Self.raise(window: window, pid: pid)

            guard let tabGroup = findTabGroup(in: window, remainingDepth: 6) else { return }
            var childrenRef: CFTypeRef?
            AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &childrenRef)
            guard let tabs = childrenRef as? [AXUIElement] else { return }
            guard let target = Self.tab(in: tabs, matchingTitle: item.title, fallbackIndex: tabIndex) else { return }
            AXUIElementPerformAction(target, kAXPressAction as CFString)
        }
    }

    private enum ItemTarget {
        case window(pid: pid_t, windowIndex: Int)
        case tab(pid: pid_t, windowIndex: Int, tabIndex: Int)
    }

    private static func parseItemID(_ id: String) -> ItemTarget? {
        let parts = id.split(separator: ":")
        switch parts.count {
        case 2:
            guard let pid = pid_t(parts[0]), let index = Int(parts[1]) else { return nil }
            return .window(pid: pid, windowIndex: index)
        case 4 where parts[2] == "tab":
            guard let pid = pid_t(parts[0]), let windowIndex = Int(parts[1]), let tabIndex = Int(parts[3]) else {
                return nil
            }
            return .tab(pid: pid, windowIndex: windowIndex, tabIndex: tabIndex)
        default:
            return nil
        }
    }

    private static func window(forPID pid: pid_t, index: Int) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
            let windows = windowsRef as? [AXUIElement],
            windows.indices.contains(index)
        else {
            return nil
        }
        return windows[index]
    }

    /// Tab order can change between the picker loading and Enter being
    /// pressed (a tab closed or reordered), so the index captured when the
    /// item list was built may no longer point at the tab the user picked.
    /// Trust the stale index first if its title still matches — the
    /// strongest signal, and the only one immune to duplicate titles when
    /// nothing actually moved — and only fall back to a title scan (which
    /// can't disambiguate duplicates) if the index is gone or its title
    /// changed out from under it.
    private static func tab(in tabs: [AXUIElement], matchingTitle title: String, fallbackIndex: Int) -> AXUIElement? {
        if tabs.indices.contains(fallbackIndex), tabTitle(tabs[fallbackIndex]) == title {
            return tabs[fallbackIndex]
        }
        if let match = tabs.first(where: { tabTitle($0) == title }) {
            return match
        }
        return tabs.indices.contains(fallbackIndex) ? tabs[fallbackIndex] : nil
    }

    private static func tabTitle(_ tab: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(tab, kAXTitleAttribute as CFString, &titleRef)
        return titleRef as? String
    }

    private static func raise(window: AXUIElement, pid: pid_t) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        NSRunningApplication(processIdentifier: pid)?.activate()
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// AX calls are synchronous IPC and can hang; `AXUIElementSetMessagingTimeout`
    /// is what actually makes a wedged call return with an error instead of
    /// blocking the thread forever — the `withDeadline` wrapper only races
    /// cooperative `async` work, so it can't rescue a stuck syscall on its own.
    private static func discoverWindows(pid: pid_t) async -> [PickerItem] {
        await withDeadline(0.15) {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 150)

            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsRef)
            guard result == .success, let windows = windowsRef as? [AXUIElement] else {
                return []
            }

            var items: [PickerItem] = []
            for (index, window) in windows.enumerated() {
                // No fallback to the app's own name here — a window with no
                // real AX title (e.g. Finder's desktop layer, which comes
                // back through kAXWindowsAttribute alongside real windows)
                // isn't something a title-fuzzy-search picker can usefully
                // represent, so it's dropped rather than shown under a
                // synthesized label.
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                guard let title = titleRef as? String, !title.isEmpty else { continue }

                var documentRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &documentRef)
                let document = documentRef as? String

                items.append(PickerItem(id: "\(pid):\(index)", title: title, secondaryText: document))
            }
            return items
        } ?? []
    }
}
