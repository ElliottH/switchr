import Cocoa

@MainActor
protocol PickerPanelDelegate: AnyObject {
    func pickerPanel(_ panel: PickerPanel, queryChanged query: String)
    func pickerPanelBackspaceAtStart(_ panel: PickerPanel)
    func pickerPanel(_ panel: PickerPanel, moveSelectionBy delta: Int)
    func pickerPanelActivateSelection(_ panel: PickerPanel)
    func pickerPanelCancel(_ panel: PickerPanel)
}

/// A non-activating panel that takes key input without deactivating the app
/// behind it — needed so the picker can still identify what was frontmost
/// when it opened. Purely a view: it reports text/key events to its delegate
/// and renders whatever result titles it's told to; ranking and activation
/// live in `PickerController`.
final class PickerPanel: NSPanel, NSTextFieldDelegate {
    weak var pickerDelegate: PickerPanelDelegate?

    private let scopeLabel = NSTextField(labelWithString: "")
    private let textField = NSTextField()
    private let resultsStack = NSStackView()
    private let textFieldAreaHeight: CGFloat = 52
    private let rowHeight: CGFloat = 28
    private let bottomPadding: CGFloat = 8
    private let panelWidth: CGFloat = 560
    private var isProgrammaticUpdate = false

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

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // A fixed-height row so the text field can be centered *within* it —
        // pinning the field itself to a tall area top-aligns its one line of
        // text instead, leaving a visible gap above the results.
        let textFieldRow = NSView()
        textFieldRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(textFieldRow)

        // Shows the locked app once a scope is committed (space-token or
        // arrow selection) — otherwise the field goes blank on commit with
        // no indication of what's selected.
        scopeLabel.translatesAutoresizingMaskIntoConstraints = false
        scopeLabel.font = .boldSystemFont(ofSize: 20)
        scopeLabel.textColor = .secondaryLabelColor
        textFieldRow.addSubview(scopeLabel)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .systemFont(ofSize: 20)
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.placeholderString = "Switch to…"
        textField.delegate = self
        textFieldRow.addSubview(textField)

        resultsStack.translatesAutoresizingMaskIntoConstraints = false
        resultsStack.orientation = .vertical
        resultsStack.spacing = 0
        resultsStack.alignment = .leading
        container.addSubview(resultsStack)

        NSLayoutConstraint.activate([
            textFieldRow.topAnchor.constraint(equalTo: container.topAnchor),
            textFieldRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textFieldRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textFieldRow.heightAnchor.constraint(equalToConstant: textFieldAreaHeight),

            scopeLabel.leadingAnchor.constraint(equalTo: textFieldRow.leadingAnchor, constant: 16),
            scopeLabel.centerYAnchor.constraint(equalTo: textFieldRow.centerYAnchor),

            textField.leadingAnchor.constraint(equalTo: scopeLabel.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: textFieldRow.trailingAnchor, constant: -16),
            textField.centerYAnchor.constraint(equalTo: textFieldRow.centerYAnchor),

            resultsStack.topAnchor.constraint(equalTo: textFieldRow.bottomAnchor),
            resultsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            resultsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        ])

        contentView = container
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // Borderless panels don't accept key by default — without this the text
    // field never focuses.
    override var canBecomeKey: Bool { true }

    // Escape reaches here, not keyDown(with:) — once the text field has
    // focus, key events go to its field editor first, and cancelOperation(_:)
    // is what Escape dispatches up the responder chain when the field editor
    // doesn't handle it itself.
    override func cancelOperation(_ sender: Any?) {
        pickerDelegate?.pickerPanelCancel(self)
    }

    func showCentered() {
        // Reset to the base (no-results) size before positioning — otherwise
        // this reopens at whatever height the previous session's result list
        // left it at, and since that height is baked into the y origin below,
        // the panel visibly lands in a different spot each time.
        var newFrame = NSRect(x: 0, y: 0, width: panelWidth, height: textFieldAreaHeight)
        if let screen = NSScreen.main {
            newFrame.origin.x = screen.visibleFrame.midX - newFrame.width / 2
            newFrame.origin.y = screen.visibleFrame.midY + screen.visibleFrame.height * 0.15
        }
        setFrame(newFrame, display: true)
        // makeKeyAndOrderFront + .nonactivatingPanel is the whole mechanism
        // here — never NSApp.activate(), or the frontmost app behind the
        // panel gets deactivated.
        makeKeyAndOrderFront(nil)
        makeFirstResponder(textField)
    }

    func hidePanel() {
        orderOut(nil)
        // Each summon should start from a blank slate, not wherever the
        // user left off last time.
        textField.stringValue = ""
        scopeLabel.stringValue = ""
    }

    /// `name` is the currently-locked app once a scope is committed, `nil`
    /// while still picking one.
    func setScope(_ name: String?) {
        scopeLabel.stringValue = name.map { "\($0) ›" } ?? ""
    }

    /// Reconciles the field's displayed text with the reducer's canonical
    /// query. Usually a no-op — but a space-token commit consumes the
    /// app-name prefix inside the reducer without the field ever being told,
    /// so left un-synced the field keeps showing (and searching against) the
    /// raw keystrokes, e.g. `"iterm "`, instead of what's actually left of
    /// the query. `isProgrammaticUpdate` stops that resync from itself
    /// reporting back as a user edit.
    func setQueryText(_ text: String) {
        guard textField.stringValue != text else { return }
        isProgrammaticUpdate = true
        textField.stringValue = text
        isProgrammaticUpdate = false
    }

    /// Rebuilds the visible row list and resizes the panel to fit, growing
    /// downward from its current top edge so the text field never jumps.
    func setResults(titles: [String], selectedIndex: Int) {
        resultsStack.arrangedSubviews.forEach {
            resultsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for (index, title) in titles.enumerated() {
            resultsStack.addArrangedSubview(makeRow(title: title, isSelected: index == selectedIndex))
        }

        let height = textFieldAreaHeight + (titles.isEmpty ? 0 : CGFloat(titles.count) * rowHeight + bottomPadding)
        var newFrame = frame
        newFrame.origin.y = frame.maxY - height
        newFrame.size.height = height
        setFrame(newFrame, display: true)
    }

    private func makeRow(title: String, isSelected: Bool) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 4
        row.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.cgColor : nil

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14)
        label.textColor = isSelected ? .white : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        row.addSubview(label)

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: panelWidth - 16),
            row.heightAnchor.constraint(equalToConstant: rowHeight),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return row
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isProgrammaticUpdate else { return }
        pickerDelegate?.pickerPanel(self, queryChanged: textField.stringValue)
    }

    // Arrow keys, Return, and backspace-with-empty-field arrive here rather
    // than keyDown(with:) once the field editor has focus — same responder-
    // chain lesson as cancelOperation(_:) above.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            pickerDelegate?.pickerPanel(self, moveSelectionBy: -1)
            return true

        case #selector(NSResponder.moveDown(_:)):
            pickerDelegate?.pickerPanel(self, moveSelectionBy: 1)
            return true

        case #selector(NSResponder.insertNewline(_:)):
            pickerDelegate?.pickerPanelActivateSelection(self)
            return true

        // Tab isn't self-inserted by the field editor the way Space is (it
        // triggers key-view navigation instead), so it never reaches the
        // reducer's app-token commit on its own — reported as though a
        // literal space had been typed, which is the one thing that logic
        // actually looks for.
        case #selector(NSResponder.insertTab(_:)):
            pickerDelegate?.pickerPanel(self, queryChanged: textField.stringValue + " ")
            return true

        case #selector(NSResponder.deleteBackward(_:)):
            guard textField.stringValue.isEmpty else { return false }
            pickerDelegate?.pickerPanelBackspaceAtStart(self)
            return true

        default:
            return false
        }
    }
}
