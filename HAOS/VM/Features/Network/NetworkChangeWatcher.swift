import Foundation
import SystemConfiguration

/// Blocks a thread until configd reports a network change — the per-interface
/// Link state the bridge selects on, or the global IPv4 dictionary that names
/// the default-route interface. Lets the start react the instant Wi-Fi
/// associates or a cable is plugged in, instead of polling for it.
final class NetworkChangeWatcher {
    private let semaphore = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "VmnetBridge.NetworkChangeWatcher")
    private var store: SCDynamicStore?

    init() {
        var context = SCDynamicStoreContext(version: 0,
                                            info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkChangeWatcher>.fromOpaque(info).takeUnretainedValue().semaphore.signal()
        }
        guard let store = SCDynamicStoreCreate(nil, "HAOS.VmnetBridge" as CFString,
                                               callback, &context) else { return }
        SCDynamicStoreSetNotificationKeys(store,
                                          ["State:/Network/Global/IPv4"] as CFArray,
                                          ["State:/Network/Interface/[^/]+/Link"] as CFArray)
        SCDynamicStoreSetDispatchQueue(store, queue)
        self.store = store
    }

    /// Waits for the next change or until `deadline`, whichever comes first.
    /// Signals accumulate, so a change that lands between a caller's check and
    /// its next wait returns immediately rather than being missed.
    func waitForChange(until deadline: Date) {
        _ = semaphore.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
    }

    /// Stops delivery and drains a callback that may already be running, so
    /// nothing touches this object after the caller lets go of it.
    func stop() {
        guard let store else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
        queue.sync {}
        self.store = nil
    }

    deinit { stop() }
}
