import ApplicationServices

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
