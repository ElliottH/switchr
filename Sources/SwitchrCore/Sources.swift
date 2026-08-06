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

/// Tab/window discovery for a single app, queried on demand only once the
/// user commits to that app — no warm cache, no cross-app latency budget.
/// Implementations fail open: a provider that errors or times out is
/// silently dropped rather than surfaced.
public protocol WindowSource: Sendable {
    func items(for app: RunningApp) async -> [PickerItem]
}
