import AppKit

// Top-level `main.swift` code runs in a synchronous nonisolated context by
// default; this is the process entry point, so it's main-thread by
// construction, but that has to be asserted explicitly for the isolation
// checker to allow constructing @MainActor types below.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
