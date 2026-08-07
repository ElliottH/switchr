/// Tier-0 app + window discovery: `NSWorkspace.runningApplications` + AX
/// windows, filtered to apps with at least one window. Async because AX
/// calls are synchronous IPC that can hang — implementations are expected to
/// fail open per app rather than let one hung app stall this.
///
/// Order matters: `PickerState`'s empty-query app list is exactly this
/// array's order, with no separate sort applied. The MRU tiebreak (built
/// from `NSWorkspace.didActivateApplicationNotification`) is this protocol's
/// responsibility to apply before returning, not the reducer's.
public protocol AppSource: Sendable {
    func runningApps() async -> [AppWithItems]
}

/// Tab/window discovery *and* activation for a single app, queried on demand
/// only once the user commits to that app — no warm cache, no cross-app
/// latency budget. Implementations fail open: a provider that errors or
/// times out is silently dropped rather than surfaced.
///
/// A single conformer owns both halves of one app's story so a caller can
/// hold one ordered `[WindowSource]` registry and drive discovery,
/// activation, and "is there a rich provider for this app" decisions all
/// from the same list, instead of hardcoding the same provider set
/// separately at each call site.
public protocol WindowSource: Sendable {
    /// Whether this is the source that owns `appID` — the deciding factor
    /// for which provider's `items(for:)` to query. Exactly one non-fallback
    /// provider should ever claim a given `appID`; a catch-all provider may
    /// claim every `appID` as long as it's ordered last in the registry.
    func owns(appID: String) -> Bool
    func items(for app: RunningApp) async -> [PickerItem]
    /// Attempts to activate `item`, returning `false` untouched if this
    /// source doesn't recognize the item's id shape — lets callers try the
    /// next source in a chain.
    func activate(item: PickerItem) async -> Bool
}
