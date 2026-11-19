import Foundation

/// Cancellation crosses from the main queue to preparation and download queues.
/// Disk edits finish their current attach/write/detach before observing it.
final class VMStartCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}
