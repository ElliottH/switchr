import Carbon.HIToolbox
import Cocoa

/// One configured chord. `onRelease` is what distinguishes a scoped hotkey's
/// hold/cycle/release interaction from the plain global toggle: `nil` means
/// "fire once per press, no held-chord session" (the global hotkey);
/// non-`nil` means each additional press while the chord is held should
/// advance a selection, and releasing any of its modifiers should commit.
struct RegisteredHotkey {
    let keyCode: CGKeyCode
    let modifierMask: CGEventFlags
    let onPress: @MainActor () -> Void
    let onRelease: (@MainActor () -> Void)?

    init(keyCode: CGKeyCode, modifierMask: CGEventFlags, onPress: @escaping @MainActor () -> Void, onRelease: (@MainActor () -> Void)? = nil) {
        self.keyCode = keyCode
        self.modifierMask = modifierMask
        self.onPress = onPress
        self.onRelease = onRelease
    }
}

/// Global hotkeys via a listen-and-consume `CGEvent` tap. An `NSEvent` global
/// monitor is passive and can't swallow the event, so the keystroke would
/// also reach the frontmost app and double-fire.
final class HotkeyTap {
    /// The only modifier bits chords are matched against — CGEventFlags
    /// carries other device-dependent bits (e.g. numeric keypad) that must
    /// not affect the comparison.
    private static let relevantModifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    private var port: CFMachPort?
    private let hotkeys: [RegisteredHotkey]
    /// Chords currently mid-hold, keyed by the physical key that armed them
    /// — set on a `keyDown` match whose hotkey has an `onRelease`, cleared
    /// once that release fires. Keyed rather than a single slot because two
    /// app-scoped hotkeys can share the same modifiers but differ by key
    /// (e.g. ⌘⌥C and ⌘⌥T both held in sequence without releasing ⌘⌥), and
    /// each physical key can only ever have one binding matching it at a
    /// time.
    private var armedHotkeys: [CGKeyCode: RegisteredHotkey] = [:]

    init(hotkeys: [RegisteredHotkey]) {
        self.hotkeys = hotkeys
    }

    /// Returns `false` if the tap couldn't be created (no Accessibility
    /// permission) — caller is expected to have already checked
    /// `AXIsProcessTrusted()`, but `tapCreate` is the authoritative check.
    @discardableResult
    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            // Tail, not head: a head-inserted tap always jumps to the front
            // of the chain, ahead of taps installed earlier — so if another
            // app's tap (e.g. a CapsLock-as-hyper remapper) transforms the
            // event's modifier flags, a head-inserted tap here could see the
            // event before that transformation happens, depending purely on
            // which app launched more recently. Tail placement always sees
            // events last, after every head-inserted tap has already run,
            // regardless of launch order.
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                Unmanaged<HotkeyTap>.fromOpaque(refcon!).takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// macOS silently disables a tap whose callback runs too slowly, and it
    /// does not recover on its own — must be handled explicitly.
    func reEnable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    // Must return immediately — real work is dispatched, never done inline,
    // since a slow tap callback gets the tap disabled by the OS.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            reEnable()
            return nil

        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.intersection(Self.relevantModifierMask)

            guard let hotkey = hotkeys.first(where: { $0.keyCode == keyCode && $0.modifierMask == flags }) else {
                return Unmanaged.passUnretained(event)
            }

            // OS-generated key-repeat while the chord is held — the original
            // press already consumed this key, so keep consuming (return
            // nil) but skip re-dispatching onPress, or holding the chord
            // would flicker the global toggle / run away past a single
            // deliberate tap on a scoped cycle.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                return nil
            }

            if hotkey.onRelease != nil {
                armedHotkeys[hotkey.keyCode] = hotkey
            }
            DispatchQueue.main.async { [onPress = hotkey.onPress] in
                MainActor.assumeIsolated { onPress() }
            }
            return nil

        case .flagsChanged:
            // Held-chord release detection only, never consumed — ordinary
            // modifier key traffic must keep flowing to every other app.
            for (keyCode, armed) in armedHotkeys where !armed.modifierMask.isSubset(of: event.flags) {
                armedHotkeys.removeValue(forKey: keyCode)
                DispatchQueue.main.async { [onRelease = armed.onRelease] in
                    MainActor.assumeIsolated { onRelease?() }
                }
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
