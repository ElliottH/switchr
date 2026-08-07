import AppKit

/// `RunningApp.id` is a bundle ID when the app has one, falling back to the
/// pid as a string for the rare app that doesn't — every AX-backed source
/// needs to reverse that back to a pid_t to talk to the Accessibility API.
func resolvePID(forAppID id: String) -> pid_t? {
    if let pid = pid_t(id) {
        return pid
    }
    return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }?.processIdentifier
}
