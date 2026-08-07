import SwitchrCore

/// No tier-1+ provider exists yet (Apple Events, companion protocol, generic
/// tab-group walk) — `AXAppSource`'s eager Tier-0 windows are the only items
/// v0 has, so this always fails open with nothing further to add.
struct StubWindowSource: WindowSource {
    func items(for app: RunningApp) async -> [PickerItem] {
        []
    }
}
