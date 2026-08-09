import Foundation

/// Runs an AppleScript as an `/usr/bin/osascript` subprocess and returns its
/// text output, or `nil` on any error, non-zero exit, or timeout.
///
/// This does **not** use `NSAppleScript` in-process. That was the first
/// attempt, and it's a real deadlock, not just a theoretical risk: a script
/// as simple as `repeat with w in windows ... end repeat` sent to Chrome via
/// `NSAppleScript.executeAndReturnError` on a background thread hangs
/// indefinitely — confirmed empirically, including with a hard `Process`
/// timeout wrapped around it. The exact same script text runs instantly via
/// `osascript`. Shelling out sidesteps whatever in-process Apple Event path
/// is broken, and as a bonus gives a genuine, killable timeout — no
/// AX-style "the deadline races the caller but the callee keeps running"
/// caveat here, since `terminate()` actually ends the subprocess.
enum AppleScriptRunner {
    private static let timeout: TimeInterval = 2.0

    /// `text item delimiters`-based replace, since AppleScript string
    /// literals have no escape sequences for control characters — sources
    /// that use this splice `ASCII character 31` in at runtime as their
    /// field separator instead of embedding it as a literal byte in the
    /// script text. Shared by every source (Chrome, iTerm2, …) that shells
    /// out multi-field rows through `osascript`'s single-line output.
    static let sanitizeHandler = """
    on sanitize(txt)
        set AppleScript's text item delimiters to {return, linefeed}
        set txt to text items of txt
        set AppleScript's text item delimiters to " "
        set txt to txt as text
        set AppleScript's text item delimiters to ""
        return txt
    end sanitize
    """

    static func run(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            let box = ResumeBox(continuation)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()

            process.terminationHandler = { proc in
                guard proc.terminationStatus == 0 else {
                    box.resume(nil)
                    return
                }
                // Fine for the output sizes here (tab/session lists, not
                // arbitrary data) — reading only after exit risks the
                // classic full-pipe deadlock once output exceeds ~64KB.
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                box.resume(String(data: data, encoding: .utf8))
            }

            do {
                try process.run()
            } catch {
                box.resume(nil)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    /// Guards the continuation against a double-resume race between the
    /// timeout's `terminate()` and a termination handler that was already
    /// mid-flight.
    private final class ResumeBox: @unchecked Sendable {
        private let continuation: CheckedContinuation<String?, Never>
        private let lock = NSLock()
        private var didResume = false

        init(_ continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: String?) {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return }
            didResume = true
            continuation.resume(returning: value)
        }
    }
}
