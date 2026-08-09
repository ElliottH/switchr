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

    /// Raises the specific Tier-0 window backing `item`, unminimising first
    /// if needed — activation is more than `AXRaise`. Tier-2 tab items
    /// (`"pid:windowIndex:tab:tabIndex"`) are `AXTabWindowSource`'s to
    /// activate, not this type's — by the time a caller falls back to this
    /// method, every `WindowSource` in the registry has already declined the
    /// item, so this only ever needs to understand its own plain-window id
    /// shape.
    ///
    /// Re-resolves by title rather than trusting `windowIndex` alone — a
    /// window can close or a new one can open ahead of it between discovery
    /// and Enter, same staleness risk `AXTabWindowSource` already guards
    /// against for tabs. `item.title` is this type's own Tier-0 window
    /// title, captured at discovery time, so it's the right signal to
    /// re-verify against.
    func activate(item: PickerItem, in app: RunningApp) {
        guard
            let pid = resolvePID(forAppID: app.id),
            let target = Self.parseWindowItemID(item.id),
            target.pid == pid,
            let window = axWindow(forPID: pid, matchingTitle: item.title, fallbackIndex: target.windowIndex)
        else {
            activate(app: app)
            return
        }
        raiseAXWindow(window, pid: pid)
    }

    private static func parseWindowItemID(_ id: String) -> (pid: pid_t, windowIndex: Int)? {
        let parts = id.split(separator: ":")
        guard parts.count == 2, let pid = pid_t(parts[0]), let windowIndex = Int(parts[1]) else { return nil }
        return (pid, windowIndex)
    }

    /// AX calls are synchronous IPC and can hang; `AXUIElementSetMessagingTimeout`
    /// is what actually makes a wedged call return with an error instead of
    /// blocking the thread forever — the `withDeadline` wrapper only races
    /// cooperative `async` work, so it can't rescue a stuck syscall on its own.
    private static func discoverWindows(pid: pid_t) async -> [PickerItem] {
        await withDeadline(0.15) {
            guard let windows = axWindows(forPID: pid, timeout: 150) else { return [] }

            var items: [PickerItem] = []
            for (index, window) in windows.enumerated() {
                // No fallback to the app's own name here — a window with no
                // real AX title (e.g. Finder's desktop layer, which comes
                // back through kAXWindowsAttribute alongside real windows)
                // isn't something a title-fuzzy-search picker can usefully
                // represent, so it's dropped rather than shown under a
                // synthesized label.
                guard let title = axTitle(of: window), !title.isEmpty else { continue }

                var documentRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &documentRef)
                let document = documentRef as? String

                items.append(PickerItem(id: "\(pid):\(index)", title: title, secondaryText: document))
            }
            return items
        } ?? []
    }
}
