import ApplicationServices
import AppKit

/// Fetches `pid`'s window list fresh via AX every call — window lists are
/// never cached across the picker's item-list lifetime, since windows can
/// close or reorder between discovery and activation.
private func axWindows(forPID pid: pid_t) -> [AXUIElement]? {
    let appElement = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
        let windows = windowsRef as? [AXUIElement]
    else {
        return nil
    }
    return windows
}

/// Re-resolves `fallbackIndex` against a freshly-fetched window list by
/// title — a window list can reorder or lose entries between discovery and
/// Enter, so the index alone captured at discovery time may no longer point
/// at the window the user picked. Delegates the actual tie-break to
/// `axElement(in:matchingTitle:fallbackIndex:)`, shared with
/// `AXTabWindowSource`'s identical staleness problem for tabs within a
/// window.
func axWindow(forPID pid: pid_t, matchingTitle title: String?, fallbackIndex: Int) -> AXUIElement? {
    guard let windows = axWindows(forPID: pid) else { return nil }
    return axElement(in: windows, matchingTitle: title, fallbackIndex: fallbackIndex)
}

/// Picks `fallbackIndex` out of `elements` by title first: trusts the stale
/// index if its title still matches (the strongest signal, and the only one
/// immune to duplicate titles when nothing actually moved), then falls back
/// to a title scan (can't disambiguate duplicates), then the stale index
/// itself as a last resort if even that comes up empty. `title` is `nil`
/// when the caller has no title signal at all (e.g. a title-less window) —
/// skips straight to the index rather than paying an AX round-trip per
/// element on a scan that can't match anything.
///
/// Generic over `AXUIElement` arrays rather than tied to windows
/// specifically — `axWindow(forPID:matchingTitle:fallbackIndex:)` uses it to
/// re-resolve a window among its app's siblings, and `AXTabWindowSource`
/// uses it directly to re-resolve a tab among its window's tab-group
/// children, the same staleness problem one level down.
func axElement(in elements: [AXUIElement], matchingTitle title: String?, fallbackIndex: Int) -> AXUIElement? {
    guard let title else {
        return elements.indices.contains(fallbackIndex) ? elements[fallbackIndex] : nil
    }
    if elements.indices.contains(fallbackIndex), axTitle(of: elements[fallbackIndex]) == title {
        return elements[fallbackIndex]
    }
    if let match = elements.first(where: { axTitle(of: $0) == title }) {
        return match
    }
    return elements.indices.contains(fallbackIndex) ? elements[fallbackIndex] : nil
}

func axTitle(of element: AXUIElement) -> String? {
    var titleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
    return titleRef as? String
}

/// Unminimises and raises `window`, activating its owning app — activation
/// is more than `AXRaise` alone.
func raiseAXWindow(_ window: AXUIElement, pid: pid_t) {
    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    NSRunningApplication(processIdentifier: pid)?.activate()
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
}

/// Shallow bounded-depth search for the first `AXTabGroup` descendant of
/// `element`. Shared between the tab walker (discovery) and activation
/// (pressing the right `AXRadioButton`) so both agree on exactly the same
/// tree shape — unbounded recursion would walk an entire window's subtree,
/// one synchronous AX call per node, on every window that simply has no
/// tabs.
func findTabGroup(in element: AXUIElement, remainingDepth: Int) -> AXUIElement? {
    guard remainingDepth > 0 else { return nil }

    var roleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
    if (roleRef as? String) == (kAXTabGroupRole as String) {
        return element
    }

    var childrenRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
    guard let children = childrenRef as? [AXUIElement] else { return nil }

    for child in children {
        if let found = findTabGroup(in: child, remainingDepth: remainingDepth - 1) {
            return found
        }
    }
    return nil
}
