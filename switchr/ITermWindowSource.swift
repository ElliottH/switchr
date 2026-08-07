import Foundation
import SwitchrCore

/// Tier-1 discovery for iTerm2 via Apple Events. `PickerItem.id` encodes
/// `"ae:iterm:<sessionID>"` — iTerm2 session ids are stable UUIDs, so unlike
/// Chrome there's no index to re-resolve at activation: `select` finds the
/// session directly.
///
/// As with `ChromeWindowSource`, each window's currently-active session
/// (`current session of current tab of window`) is deliberately **not**
/// emitted — the Tier-0 AX window entry already lands on it when raised.
/// Every *other* session (other split panes in the active tab, and every
/// session in every other tab) gets its own row.
final class ITermWindowSource: WindowSource {
    static let bundleID = "com.googlecode.iterm2"

    func items(for app: RunningApp) async -> [PickerItem] {
        guard app.id == Self.bundleID else { return [] }
        guard let output = await AppleScriptRunner.run(Self.discoverySource) else { return [] }
        return Self.parse(output)
    }

    /// Returns `false` (without touching iTerm2) if `item` wasn't produced
    /// by this source, so callers can fall through to the next activator.
    func activate(item: PickerItem) async -> Bool {
        guard let sessionID = Self.parseItemID(item.id) else { return false }
        _ = await AppleScriptRunner.run(Self.activationSource(sessionID: sessionID))
        return true
    }

    private static func parseItemID(_ id: String) -> String? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "ae", parts[1] == "iterm" else { return nil }
        let sessionID = String(parts[2])
        // iTerm2 session ids are UUIDs — restrict to that charset before
        // splicing into a quoted AppleScript string literal.
        guard !sessionID.isEmpty, sessionID.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return sessionID
    }

    private static func parse(_ output: String) -> [PickerItem] {
        var items: [PickerItem] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let sessionID = String(fields[0])
            let name = String(fields[1])
            guard !name.isEmpty else { continue }
            items.append(PickerItem(id: "ae:iterm:\(sessionID)", title: name))
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
    tell application "iTerm2"
        repeat with w in windows
            set activeSessionID to (id of (current session of current tab of w)) as text
            repeat with tb in tabs of w
                repeat with s in sessions of tb
                    set sid to (id of s as text)
                    if sid is not activeSessionID then
                        set out to out & sid & fs & my sanitize(name of s) & linefeed
                    end if
                end repeat
            end repeat
        end repeat
    end tell
    return out
    """

    /// `sessionID` is validated as UUID-charset-only by `parseItemID`
    /// before reaching here, so it's safe to splice into the quoted literal.
    ///
    /// `select` on the session alone is a no-op if it isn't in the window's
    /// *current* tab — confirmed empirically, the session becomes "current"
    /// only after its tab is selected first. Selecting the window too
    /// covers the multi-window case, matching "activation is more than
    /// raise" from the AX side.
    private static func activationSource(sessionID: String) -> String {
        """
        tell application "iTerm2" to activate
        tell application "iTerm2"
            repeat with w in windows
                repeat with tb in tabs of w
                    repeat with s in sessions of tb
                        if (id of s as text) is "\(sessionID)" then
                            select w
                            select tb
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }
}
