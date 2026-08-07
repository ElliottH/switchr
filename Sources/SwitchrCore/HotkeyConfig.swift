/// A single configured hotkey, as data — key name and modifier names are raw
/// strings from the config file, not yet resolved to `CGKeyCode`/`CGEventFlags`;
/// that resolution is platform-specific and belongs to the app target.
public struct HotkeyBinding: Equatable, Sendable {
    /// One app, a set of apps, or every app — a predicate rather than a
    /// single bundle ID, so a future "all terminals" style scope doesn't
    /// require reshaping this type.
    public enum Scope: Equatable, Sendable {
        case global
        case apps([String])
    }

    public let key: String
    public let modifiers: Set<String>
    public let scope: Scope

    public init(key: String, modifiers: Set<String>, scope: Scope) {
        self.key = key
        self.modifiers = modifiers
        self.scope = scope
    }
}

/// Parses the narrow TOML subset the design doc's `[[hotkey]]` config uses:
/// array-of-tables, plain string/string-array values, and one inline table
/// shape (`{ apps = [...] }`). Not a general TOML parser — anything outside
/// that shape (multi-line strings, nested inline tables, numbers, dates) is
/// simply not a hotkey config this app needs to read.
public enum HotkeyConfigParser {
    public static func parse(_ text: String) -> [HotkeyBinding] {
        var bindings: [HotkeyBinding] = []
        var key: String?
        var modifiers: [String] = []
        var scope: HotkeyBinding.Scope?

        func flush() {
            guard let key, let scope else { return }
            bindings.append(HotkeyBinding(key: key, modifiers: Set(modifiers), scope: scope))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line == "[[hotkey]]" {
                flush()
                key = nil
                modifiers = []
                scope = nil
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let field = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            switch field {
            case "key":
                key = parseString(value)
            case "modifiers":
                modifiers = parseStringArray(value)
            case "scope":
                scope = parseScope(value)
            default:
                continue
            }
        }
        flush()
        return bindings
    }

    private static func stripComment(_ line: Substring) -> Substring {
        var inQuotes = false
        for index in line.indices {
            if line[index] == "\"" {
                inQuotes.toggle()
            } else if line[index] == "#" && !inQuotes {
                return line[..<index]
            }
        }
        return line
    }

    private static func parseString(_ text: String) -> String? {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return nil }
        return String(text.dropFirst().dropLast())
    }

    private static func parseStringArray(_ text: String) -> [String] {
        guard text.hasPrefix("["), text.hasSuffix("]") else { return [] }
        let inner = text.dropFirst().dropLast()
        return splitTopLevel(inner, on: ",").compactMap { parseString($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Splits on `separator` only outside quoted strings, so a quoted value
    /// containing the separator (e.g. a bundle ID with a comma in it)
    /// survives intact instead of being corrupted mid-token.
    private static func splitTopLevel(_ text: Substring, on separator: Character) -> [Substring] {
        var fields: [Substring] = []
        var fieldStart = text.startIndex
        var inQuotes = false
        for index in text.indices {
            let char = text[index]
            if char == "\"" {
                inQuotes.toggle()
            } else if char == separator && !inQuotes {
                fields.append(text[fieldStart..<index])
                fieldStart = text.index(after: index)
            }
        }
        fields.append(text[fieldStart...])
        return fields
    }

    /// `"global"` or `{ apps = [...] }` — the only two scope shapes the
    /// config format defines.
    private static func parseScope(_ text: String) -> HotkeyBinding.Scope? {
        if let string = parseString(text) {
            return string == "global" ? .global : nil
        }
        guard text.hasPrefix("{"), text.hasSuffix("}") else { return nil }
        let inner = text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard let eq = inner.firstIndex(of: "=") else { return nil }
        let field = inner[..<eq].trimmingCharacters(in: .whitespaces)
        guard field == "apps" else { return nil }
        let value = inner[inner.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        let apps = parseStringArray(value)
        return apps.isEmpty ? nil : .apps(apps)
    }
}
