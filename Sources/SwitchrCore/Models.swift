/// A running application, as surfaced at stage one of the picker.
public struct RunningApp: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A window or tab belonging to a single app — the stage-two haystack.
public struct PickerItem: Equatable, Identifiable, Sendable {
    /// Must be unique across *all* apps, not just within one — global
    /// fallthrough resolves a selection by scanning every app's items.
    public let id: String
    public let title: String
    /// A lower-weighted secondary field (e.g. a browser tab's URL). Matched,
    /// not necessarily displayed.
    public let secondaryText: String?

    public init(id: String, title: String, secondaryText: String? = nil) {
        self.id = id
        self.title = title
        self.secondaryText = secondaryText
    }
}

/// A running app paired with its Tier-0 (AX window) items, known eagerly at
/// enumeration time — this is what already exists once the "has ≥1 window"
/// stage-one filter has run, so it's threaded through rather than re-queried.
public struct AppWithItems: Equatable, Sendable {
    public let app: RunningApp
    public let items: [PickerItem]

    public init(app: RunningApp, items: [PickerItem]) {
        self.app = app
        self.items = items
    }
}
