import AppKit
import ServiceManagement

/// Menu bar shell, cloned from hypr (the event tap, menu bar app shape, and
/// Login Items registration all transfer directly from that project). The
/// CGEventTap itself and its Handler are the next piece — this just gets a
/// launchable, signable `.app` up with the permission plumbing both the tap
/// and the AX-based AppSource will need.
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusTimer: Timer?
    private var isAccessibilityGranted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        isAccessibilityGranted = AXIsProcessTrusted()
        setupMenuBar()
        registerLaunchAtLogin()
        if !isAccessibilityGranted {
            CGRequestPostEventAccess()
        }
        startStatusPolling()
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
        updateStatusIcon()
        rebuildMenu()
    }
}
