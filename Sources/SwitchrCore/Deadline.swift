import Foundation

/// Races `operation` against a deadline, returning `nil` if it doesn't finish
/// in time. Window/tab providers get a hard deadline (~150ms): a hang or
/// timeout drops that provider from the current query rather than stalling
/// the picker for everyone else — fail open, always.
///
/// `cancelAll()` is cooperative — it does not stop a synchronous hang inside
/// `operation` (e.g. an Accessibility API call blocked on IPC). A slow
/// operation keeps running detached after the deadline; its result is just
/// discarded.
public func withDeadline<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
