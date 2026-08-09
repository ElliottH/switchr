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
    /// The AX title of the window this item's tab lives in, captured once at
    /// discovery time — `nil` for id shapes that don't need it (Tier-0
    /// window items already double as their own "window title" via `title`).
    /// Lets activation re-resolve the owning window by title instead of
    /// trusting a stale index, the same way `title` itself is used to
    /// re-resolve Tier-0 windows and tabs.
    public let windowTitle: String?

    public init(id: String, title: String, secondaryText: String? = nil, windowTitle: String? = nil) {
        self.id = id
        self.title = title
        self.secondaryText = secondaryText
        self.windowTitle = windowTitle
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
