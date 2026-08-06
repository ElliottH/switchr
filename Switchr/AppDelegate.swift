import AppKit
import ServiceManagement

/// Menu bar shell, cloned from hypr (the event tap, menu bar app shape, and
/// Login Items registration all transfer directly from that project).
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusTimer: Timer?
    private var isAccessibilityGranted = false
    private var hotkeyTap: HotkeyTap?
    private var panel: PickerPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        isAccessibilityGranted = AXIsProcessTrusted()
        setupMenuBar()
        registerLaunchAtLogin()
        if !isAccessibilityGranted {
            CGRequestPostEventAccess()
        } else {
            startEventTap()
        }
        startStatusPolling()
    }

    private func startEventTap() {
        let tap = HotkeyTap { [weak self] in
            self?.togglePanel()
        }
        guard tap.start() else { return }
        hotkeyTap = tap
    }

    private func togglePanel() {
        let panel = panel ?? {
            let panel = PickerPanel()
            self.panel = panel
            return panel
        }()

        if panel.isVisible {
            panel.hidePanel()
            return
        }

        let activeBefore = NSApp.isActive
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        panel.showCentered()
        print(
            "[Switchr] panel shown — NSApp.isActive: \(activeBefore) -> \(NSApp.isActive), "
                + "frontmost: \(frontmostBefore) -> \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")"
        )
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        rebuildMenu()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Switchr")
        image?.isTemplate = true
        button.image = image
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        if !isAccessibilityGranted {
            let infoItem = NSMenuItem(title: "Accessibility permission required", action: nil, keyEquivalent: "")
            infoItem.isEnabled = false
            menu.addItem(infoItem)
            menu.addItem(NSMenuItem(title: "Open System Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
            menu.addItem(.separator())
        }

        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        #if DEBUG
        // Exercises the panel's non-activation without needing Accessibility
        // permission granted or the real hotkey — see the log line in
        // togglePanel() for the NSApp.isActive / frontmost-app assertion.
        menu.addItem(NSMenuItem(title: "Show Picker (Debug)", action: #selector(debugShowPicker), keyEquivalent: ""))
        menu.addItem(.separator())
        #endif
        menu.addItem(NSMenuItem(title: "Quit Switchr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first(where: { $0.action == #selector(toggleLaunchAtLogin) })?.state =
            SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            try? service.unregister()
        } else {
            try? service.register()
        }
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    #if DEBUG
    @objc private func debugShowPicker() {
        togglePanel()
    }
    #endif

    private func registerLaunchAtLogin() {
        if SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
    }

    private func startStatusPolling() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
    }

    private func pollStatus() {
        let newAccessibility = AXIsProcessTrusted()
        guard newAccessibility != isAccessibilityGranted else { return }
        isAccessibilityGranted = newAccessibility
        // Accessibility permission is keyed to the code signature and can be
        // granted after launch — `tapCreate` fails silently without it, so
        // the tap has to be (re-)started once it's actually available.
        if newAccessibility && hotkeyTap == nil {
            startEventTap()
        }
        updateStatusIcon()
        rebuildMenu()
    }
}
