import Foundation
import SwitchrCore

/// Tier-1 discovery for Chrome via Apple Events. `PickerItem.id` encodes
/// `"ae:chrome:<windowID>:<tabID>"` — both are Chrome's own stable AppleScript
/// ids (not indices), captured at query time; activation re-resolves the
/// tab's *current* index from `tabID` since Chrome addresses tabs by index
/// and that index can shift between query and Enter.
///
/// The window's currently-active tab is deliberately **not** emitted here.
/// The Tier-0 AX window entry (from `AXAppSource`) already represents
/// "raise this window", which lands on whatever tab is active in it — same
/// tab, queried moments apart, staleness being a non-issue per the design
/// doc. Omitting it sidesteps ever needing to match an AX window to its
/// Chrome AppleScript counterpart, which would otherwise be required to
/// dedupe the two entries and is genuinely hard: windows from *other* Chrome
/// profiles are AX-visible but invisible to `tell application "Google
/// Chrome"`, so there's no reliable correspondence to lean on. Those
/// other-profile windows simply keep showing only their Tier-0 entry, with
/// their other tabs unreachable via Apple Events — the documented fallback.
final class ChromeWindowSource: WindowSource {
    static let bundleID = "com.google.Chrome"

    func items(for app: RunningApp) async -> [PickerItem] {
        guard app.id == Self.bundleID else { return [] }
        guard let output = await AppleScriptRunner.run(Self.discoverySource) else { return [] }
        return Self.parse(output)
    }

    /// Returns `false` (without touching Chrome) if `item` wasn't produced
    /// by this source, so callers can fall through to the next activator.
    func activate(item: PickerItem) async -> Bool {
        guard let target = Self.parseItemID(item.id) else { return false }
        _ = await AppleScriptRunner.run(Self.activationSource(windowID: target.windowID, tabID: target.tabID))
        return true
    }

    private static func parseItemID(_ id: String) -> (windowID: String, tabID: String)? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "ae", parts[1] == "chrome" else { return nil }
        let windowID = String(parts[2])
        let tabID = String(parts[3])
        guard !windowID.isEmpty, windowID.allSatisfy(\.isNumber),
              !tabID.isEmpty, tabID.allSatisfy(\.isNumber)
        else { return nil }
        return (windowID, tabID)
    }

    private static func parse(_ output: String) -> [PickerItem] {
        var items: [PickerItem] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard fields.count == 4 else { continue }
            let windowID = String(fields[0])
            let tabID = String(fields[1])
            let title = String(fields[2])
            let url = String(fields[3])
            guard !title.isEmpty else { continue }
            items.append(PickerItem(id: "ae:chrome:\(windowID):\(tabID)", title: title, secondaryText: url.isEmpty ? nil : url))
        }
        return items
    }

    // `text item delimiters`-based replace, since AppleScript string
    // literals have no escape sequences for control characters — the field
    // separator below is built at runtime via `ASCII character 31` instead
    // of being embedded as a literal byte in this source string.
    private static let sanitizeHandler = """
    on sanitize(txt)
        set AppleScript's text item delimiters to {return, linefeed}
        set txt to text items of txt
        set AppleScript's text item delimiters to " "
        set txt to txt as text
        set AppleScript's text item delimiters to ""
        return txt
    end sanitize
    """

    private static let discoverySource = """
    \(sanitizeHandler)
    set fs to ASCII character 31
    set out to ""
    tell application "Google Chrome"
        repeat with w in windows
            set wid to id of w as text
            set activeIdx to active tab index of w
            set n to count of tabs of w
            repeat with i from 1 to n
                if i is not activeIdx then
                    set t to tab i of w
                    set out to out & wid & fs & (id of t as text) & fs & my sanitize(title of t) & fs & my sanitize(URL of t) & linefeed
                end if
            end repeat
        end repeat
    end tell
    return out
    """

    /// `windowID`/`tabID` are validated all-digit by `parseItemID` before
    /// reaching here, so they're safe to splice directly into the script
    /// text as bare (window id) or quoted (tab id comparison) literals.
    private static func activationSource(windowID: String, tabID: String) -> String {
        """
        tell application "Google Chrome" to activate
        tell application "Google Chrome"
            set theWindow to window id \(windowID)
            set n to count of tabs of theWindow
            set foundIndex to 0
            repeat with i from 1 to n
                if (id of (tab i of theWindow) as text) is "\(tabID)" then
                    set foundIndex to i
                end if
            end repeat
            if foundIndex > 0 then
                set active tab index of theWindow to foundIndex
            end if
            try
                set minimized of theWindow to false
            end try
            set index of theWindow to 1
        end tell
        """
    }
}
