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
    private let resultsScrollView = NSScrollView()
    private let textFieldAreaHeight: CGFloat = 52
    private let rowHeight: CGFloat = 28
    private let bottomPadding: CGFloat = 8
    private let panelWidth: CGFloat = 560
    /// Rows visible without scrolling — beyond this, `resultsScrollView`
    /// scrolls instead of the panel growing past the screen edge. Keyboard
    /// selection still reaches every ranked candidate, not just these first
    /// few; `setResults` scrolls the selected row into view as it moves.
    private let maxVisibleRows = 8
    private var isProgrammaticUpdate = false
    private var resultsHeightConstraint: NSLayoutConstraint!

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

        // NSVisualEffectView, not a plain NSView with a manually-set CALayer
        // background color: a dynamic NSColor's `.cgColor` is a one-time
        // snapshot that never updates again, so a hand-set layer color goes
        // stale the moment the system's light/dark appearance changes after
        // launch. The vibrancy material tracks appearance automatically.
        let container = NSVisualEffectView()
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true

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

        // Rows stretch to full width via their own explicit leading/trailing
        // pins to resultsStack (see makeRow) rather than stack alignment —
        // NSStackView's `.width` alignment sizes arranged views equal to
        // each other and centers them, it doesn't fill the container.
        resultsStack.translatesAutoresizingMaskIntoConstraints = false
        resultsStack.orientation = .vertical
        resultsStack.spacing = 0
        resultsStack.alignment = .leading

        resultsScrollView.translatesAutoresizingMaskIntoConstraints = false
        resultsScrollView.drawsBackground = false
        resultsScrollView.hasVerticalScroller = true
        // A permanently-visible scroller (autohidesScrollers = false)
        // rendered a stray square-cornered artifact against this view's
        // vibrancy background — its knob doesn't composite against
        // NSVisualEffectView the way it does over an opaque background.
        // Default overlay auto-hiding avoids that and still surfaces on
        // scroll or via the explicit flashScrollers() call below.
        resultsScrollView.autohidesScrollers = true
        resultsScrollView.hasHorizontalScroller = false
        resultsScrollView.documentView = resultsStack
        container.addSubview(resultsScrollView)

        resultsHeightConstraint = resultsScrollView.heightAnchor.constraint(equalToConstant: 0)

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

            resultsScrollView.topAnchor.constraint(equalTo: textFieldRow.bottomAnchor),
            resultsScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            resultsScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            resultsHeightConstraint,

            resultsStack.topAnchor.constraint(equalTo: resultsScrollView.contentView.topAnchor),
            resultsStack.leadingAnchor.constraint(equalTo: resultsScrollView.contentView.leadingAnchor),
            resultsStack.widthAnchor.constraint(equalTo: resultsScrollView.contentView.widthAnchor),
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
        // AppKit doesn't automatically recompute a borderless window's
        // shadow to match a programmatically-masked (rounded-corner)
        // content view on every arbitrary resize — without this, the
        // shadow can stay shaped for a stale frame, showing as a hard edge
        // that doesn't follow the rounded corners.
        invalidateShadow()
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
            let row = makeRow(title: title, isSelected: index == selectedIndex)
            resultsStack.addArrangedSubview(row)
            // Only pinned to resultsStack once it's actually a subview of
            // it — activating this inside makeRow, before the row has any
            // superview, has no common ancestor for Auto Layout to solve
            // against.
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: resultsStack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: resultsStack.trailingAnchor),
            ])
        }

        // The panel itself only ever grows tall enough for maxVisibleRows —
        // beyond that, resultsScrollView scrolls instead of the window
        // marching off the bottom of the screen. Every ranked candidate is
        // still reachable by arrow key; only the *viewport* is capped.
        //
        // resultsScrollView's own height stops short of bottomPadding,
        // leaving it inset from the container's bottom edge — matching the
        // pre-scroll-view layout, where the stack view's unconstrained
        // bottom left the same implicit gap above the window's edge.
        let visibleRowCount = min(titles.count, maxVisibleRows)
        let listHeight = titles.isEmpty ? 0 : CGFloat(visibleRowCount) * rowHeight + bottomPadding
        resultsHeightConstraint.constant = titles.isEmpty ? 0 : CGFloat(visibleRowCount) * rowHeight

        let height = textFieldAreaHeight + listHeight
        var newFrame = frame
        newFrame.origin.y = frame.maxY - height
        newFrame.size.height = height
        setFrame(newFrame, display: true)
        invalidateShadow()

        if titles.count > maxVisibleRows {
            resultsScrollView.flashScrollers()
        }

        if titles.indices.contains(selectedIndex) {
            // Force layout first — scrolling to a row's bounds before the
            // stack has actually laid out this update's rows targets stale
            // (or, for a freshly-added row, zero) geometry, most visibly
            // wrong on the wraparound jump from the last row back to the
            // first (or vice versa) rather than a simple one-row step.
            resultsStack.layoutSubtreeIfNeeded()
            let row = resultsStack.arrangedSubviews[selectedIndex]
            row.scrollToVisible(row.bounds)
        }
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

        // No fixed width here — NSStackView's `.width`/`.height` alignment
        // options size arranged views *equal to each other* and center them,
        // they don't stretch a view to fill the stack's own bounds (an easy
        // AppKit gotcha — this was tried first and produced narrow,
        // right-of-center rows instead of full-width ones). The caller pins
        // each row's leading/trailing to resultsStack once it's actually
        // been added as an arranged subview — doing that here, before this
        // view has any superview, has no common ancestor for Auto Layout to
        // solve against.
        NSLayoutConstraint.activate([
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
