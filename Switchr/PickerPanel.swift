import Carbon.HIToolbox
import Cocoa

/// A non-activating panel that takes key input without deactivating the app
/// behind it — needed so the picker can still identify what was frontmost
/// when it opened, since activating a window would make the picker itself
/// the frontmost app. Content is a placeholder text field for now; real
/// picker/reducer wiring is a later piece.
final class PickerPanel: NSPanel {
    private let textField = NSTextField()

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let container = NSView(frame: contentRect)
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .systemFont(ofSize: 20)
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.placeholderString = "Switch to…"
        container.addSubview(textField)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            textField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        contentView = container
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // Borderless panels don't accept key by default — without this the text
    // field never focuses.
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == kVK_Escape {
            hidePanel()
            return
        }
        super.keyDown(with: event)
    }

    func showCentered() {
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - frame.width / 2
            let y = screen.visibleFrame.midY + screen.visibleFrame.height * 0.15
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        // makeKeyAndOrderFront + .nonactivatingPanel is the whole mechanism
        // here — never NSApp.activate(), or the frontmost app behind the
        // panel gets deactivated.
        makeKeyAndOrderFront(nil)
        makeFirstResponder(textField)
    }

    func hidePanel() {
        orderOut(nil)
    }
}
