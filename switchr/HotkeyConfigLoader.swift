import Carbon.HIToolbox
import Cocoa
import SwitchrCore

/// Resolves the string vocabulary `HotkeyBinding` reads from TOML into the
/// Carbon/CGEvent types the tap actually matches against.
enum KeyCodeMap {
    private static let keyCodesByName: [String: CGKeyCode] = [
        "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C),
        "d": CGKeyCode(kVK_ANSI_D), "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
        "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H), "i": CGKeyCode(kVK_ANSI_I),
        "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
        "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O),
        "p": CGKeyCode(kVK_ANSI_P), "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
        "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T), "u": CGKeyCode(kVK_ANSI_U),
        "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
        "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
        "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2),
        "3": CGKeyCode(kVK_ANSI_3), "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
        "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7), "8": CGKeyCode(kVK_ANSI_8),
        "9": CGKeyCode(kVK_ANSI_9),
        "space": CGKeyCode(kVK_Space), "tab": CGKeyCode(kVK_Tab), "return": CGKeyCode(kVK_Return),
        "escape": CGKeyCode(kVK_Escape), "delete": CGKeyCode(kVK_Delete),
        "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
        "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow)
    ]

    static func keyCode(forName name: String) -> CGKeyCode? {
        keyCodesByName[name.lowercased()]
    }

    /// `nil` if any name in `names` isn't a recognized modifier — an
    /// unrecognized name changes what chord the user thinks they configured,
    /// so the whole binding must be rejected rather than silently narrowed.
    static func modifierFlags(forNames names: Set<String>) -> CGEventFlags? {
        var flags: CGEventFlags = []
        for name in names {
            switch name.lowercased() {
            case "command", "cmd": flags.insert(.maskCommand)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: return nil
            }
        }
        return flags
    }
}

enum HotkeyConfigLoader {
    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/switchr/hotkeys.toml")
    }

    /// `[]` on a missing file, an unreadable file, or a file with no valid
    /// entries — the caller falls back to the hardcoded default hotkey in
    /// every one of those cases, so there's nothing more specific to report.
    static func loadBindings() -> [HotkeyBinding] {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
        return HotkeyConfigParser.parse(text)
    }

    /// Unresolvable entries (an unknown key or modifier name) are dropped
    /// rather than failing the whole config — one typo in a scoped hotkey
    /// shouldn't cost the user every other binding.
    static func buildHotkeys(from bindings: [HotkeyBinding], pickerController: PickerController) -> [RegisteredHotkey] {
        bindings.compactMap { binding in
            guard let keyCode = KeyCodeMap.keyCode(forName: binding.key) else { return nil }
            guard let modifierMask = KeyCodeMap.modifierFlags(forNames: binding.modifiers) else { return nil }
            let scope = binding.scope

            switch scope {
            case .global:
                return RegisteredHotkey(
                    keyCode: keyCode,
                    modifierMask: modifierMask,
                    onPress: { [weak pickerController] in pickerController?.hotkeyPressed(scope: scope) }
                )
            case .apps:
                return RegisteredHotkey(
                    keyCode: keyCode,
                    modifierMask: modifierMask,
                    onPress: { [weak pickerController] in pickerController?.hotkeyPressed(scope: scope) },
                    onRelease: { [weak pickerController] in pickerController?.hotkeyReleased(scope: scope) }
                )
            }
        }
    }
}
