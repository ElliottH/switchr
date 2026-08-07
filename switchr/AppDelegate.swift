import AppKit
import ServiceManagement

/// Menu bar shell, cloned from hypr (the event tap, menu bar app shape, and
/// Login Items registration all transfer directly from that project).
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusTimer: Timer?
    private var isAccessibilityGranted = false
    private var hotkeyTap: HotkeyTap?
    private let appSource = AXAppSource()
    private lazy var pickerController = PickerController(appSource: appSource)

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
        let bindings = HotkeyConfigLoader.loadBindings()
        let resolvedHotkeys = HotkeyConfigLoader.buildHotkeys(from: bindings, pickerController: pickerController)
        // No config file, or one with no valid entries: the one hardcoded
        // hyper+space global hotkey this app has always shipped with.
        let hotkeys = resolvedHotkeys.isEmpty ? defaultHotkeys() : resolvedHotkeys
        let tap = HotkeyTap(hotkeys: hotkeys)
        guard tap.start() else { return }
        hotkeyTap = tap
    }

    private func defaultHotkeys() -> [RegisteredHotkey] {
        guard let keyCode = KeyCodeMap.keyCode(forName: "space") else { return [] }
        let modifierMask = KeyCodeMap.modifierFlags(forNames: ["command", "option", "control", "shift"])
        return [RegisteredHotkey(keyCode: keyCode, modifierMask: modifierMask, onPress: { [weak self] in
            self?.togglePanel()
        })]
    }

    private func togglePanel() {
        let activeBefore = NSApp.isActive
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        pickerController.toggle()
        print(
            "[switchr] panel toggled — NSApp.isActive: \(activeBefore) -> \(NSApp.isActive), "
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
        let image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "switchr")
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
        menu.addItem(NSMenuItem(title: "Quit switchr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

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
            Task { @MainActor in
                self?.pollStatus()
            }
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
