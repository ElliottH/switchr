import ApplicationServices
import Cocoa
import SwitchrCore

/// Tier-2 discovery for the *generic* case only: walks each window's AX tree
/// looking for a standard `AXTabGroup` → `AXRadioButton` structure. No
/// per-app table — this is exactly what covers Finder and the rest of the
/// native-window-tabbing family without a per-app entry. Table-driven
/// overrides for apps that don't fit this shape (Notion, custom-painted tab
/// bars) are later work.
///
/// `PickerItem.id` encodes `"pid:windowIndex:tab:tabIndex"` — a distinct
/// shape from `AXAppSource`'s Tier-0 `"pid:windowIndex"` window items, which
/// is how this type's own `activate(item:)` tells its ids apart from a
/// plain window's and declines (`false`) rather than mishandling one.
final class AXTabWindowSource: WindowSource {
    private let maxWalkDepth = 6

    /// The generic catch-all: every app not claimed by a richer Tier-1
    /// provider falls to this one, so it must be ordered last in any
    /// registry that dispatches by `owns`.
    func owns(appID: String) -> Bool { true }

    func items(for app: RunningApp) async -> [PickerItem] {
        guard let pid = resolvePID(forAppID: app.id) else { return [] }
        return await Self.discoverTabs(pid: pid, maxDepth: maxWalkDepth)
    }

    /// Returns `false` (without touching AX) if `item.id` isn't the
    /// `"pid:windowIndex:tab:tabIndex"` shape this source mints — lets
    /// callers fall through to the next activator (ultimately `AXAppSource`'s
    /// plain-window activation for Tier-0 `"pid:windowIndex"` ids, which this
    /// source never produces).
    ///
    /// Unlike Chrome/iTerm's `activate(item:)`, which only shells out to
    /// AppleScript, this one calls `NSRunningApplication.activate()` and
    /// mutates AX elements directly — both expected to run on the main
    /// thread. This type has no actor affinity of its own, so that work is
    /// explicitly marshalled onto the main actor rather than left to
    /// whichever executor a nonisolated `async` call happens to land on.
    ///
    /// Re-resolves the *window* by title before re-resolving the *tab* within
    /// it — the window list can reorder or lose entries between discovery
    /// and Enter just as easily as the tab list can, same staleness risk
    /// `AXAppSource` already guards against for Tier-0 windows. `item.windowTitle`
    /// is the owning window's AX title, captured once at discovery time in
    /// `discoverTabs`.
    func activate(item: PickerItem) async -> Bool {
        guard let target = Self.parseItemID(item.id) else { return false }
        return await MainActor.run {
            guard
                let window = axWindow(
                    forPID: target.pid,
                    matchingTitle: item.windowTitle ?? "",
                    fallbackIndex: target.windowIndex
                )
            else { return false }
            raiseAXWindow(window, pid: target.pid)

            guard let tabGroup = findTabGroup(in: window, remainingDepth: maxWalkDepth) else { return true }
            var childrenRef: CFTypeRef?
            AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &childrenRef)
            guard let tabs = childrenRef as? [AXUIElement] else { return true }
            guard let tab = Self.tab(in: tabs, matchingTitle: item.title, fallbackIndex: target.tabIndex) else { return true }
            AXUIElementPerformAction(tab, kAXPressAction as CFString)
            return true
        }
    }

    private static func parseItemID(_ id: String) -> (pid: pid_t, windowIndex: Int, tabIndex: Int)? {
        let parts = id.split(separator: ":")
        guard parts.count == 4, parts[2] == "tab",
              let pid = pid_t(parts[0]), let windowIndex = Int(parts[1]), let tabIndex = Int(parts[3])
        else {
            return nil
        }
        return (pid, windowIndex, tabIndex)
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

    /// AX calls are synchronous IPC and can hang; `AXUIElementSetMessagingTimeout`
    /// is what actually makes a wedged call return with an error instead of
    /// blocking the thread forever — `withDeadline` only races cooperative
    /// `async` work, so it can't rescue a stuck syscall on its own.
    private static func discoverTabs(pid: pid_t, maxDepth: Int) async -> [PickerItem] {
        await withDeadline(0.15) {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 150)

            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsRef)
            guard result == .success, let windows = windowsRef as? [AXUIElement] else {
                return []
            }

            var items: [PickerItem] = []
            for (windowIndex, window) in windows.enumerated() {
                guard let tabGroup = findTabGroup(in: window, remainingDepth: maxDepth) else { continue }

                var childrenRef: CFTypeRef?
                AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &childrenRef)
                guard let tabs = childrenRef as? [AXUIElement] else { continue }

                let windowTitle = axTitle(of: window)

                for (tabIndex, tab) in tabs.enumerated() {
                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(tab, kAXTitleAttribute as CFString, &titleRef)
                    guard let title = titleRef as? String, !title.isEmpty else { continue }

                    // The selected tab's title is also the window's own
                    // Tier-0 title — reusing that item's id here, rather than
                    // minting a distinct tab id, lets the reducer's existing
                    // "skip an id already present" rule in `itemsLoaded`
                    // collapse the duplicate for free instead of showing the
                    // same window twice.
                    var valueRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(tab, kAXValueAttribute as CFString, &valueRef)
                    let isSelected = (valueRef as? NSNumber)?.intValue == 1
                    let id = isSelected ? "\(pid):\(windowIndex)" : "\(pid):\(windowIndex):tab:\(tabIndex)"

                    items.append(PickerItem(id: id, title: title, windowTitle: windowTitle))
                }
            }
            return items
        } ?? []
    }
}
