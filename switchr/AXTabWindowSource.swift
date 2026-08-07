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
/// is how `AXAppSource.activate(item:in:)` tells the two apart.
final class AXTabWindowSource: WindowSource {
    private let maxWalkDepth = 6

    func items(for app: RunningApp) async -> [PickerItem] {
        guard let pid = resolvePID(forAppID: app.id) else { return [] }
        return await Self.discoverTabs(pid: pid, maxDepth: maxWalkDepth)
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

                    items.append(PickerItem(id: id, title: title))
                }
            }
            return items
        } ?? []
    }
}
