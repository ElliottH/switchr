import Carbon.HIToolbox
import Cocoa

/// Global hotkey via a listen-and-consume `CGEvent` tap. An `NSEvent` global
/// monitor is passive and can't swallow the event, so the keystroke would
/// also reach the frontmost app and double-fire. v0 ships one hardcoded
/// global hotkey (hyper+Space, i.e. ⌘⌥⌃⇧+Space); per-app scoped hotkeys and
/// a config file to define them are later work.
final class HotkeyTap {
    private var port: CFMachPort?
    private let onTrigger: () -> Void

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    /// Returns `false` if the tap couldn't be created (no Accessibility
    /// permission) — caller is expected to have already checked
    /// `AXIsProcessTrusted()`, but `tapCreate` is the authoritative check.
    @discardableResult
    func start() -> Bool {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue

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
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let isTriggerChord = keyCode == kVK_Space
                && flags.contains(.maskCommand)
                && flags.contains(.maskAlternate)
                && flags.contains(.maskControl)
                && flags.contains(.maskShift)

            guard isTriggerChord else {
                return Unmanaged.passUnretained(event)
            }

            DispatchQueue.main.async { [onTrigger] in
                onTrigger()
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
