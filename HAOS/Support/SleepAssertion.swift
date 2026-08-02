import Foundation

/// Keeps the Mac awake for as long as it's held.
///
/// A host that idle-sleeps freezes the guest; LAN peers then expire their ARP
/// entries and reset every persistent connection to Home Assistant, so each
/// wake costs seconds of reconnection lag (or drops events entirely). Holding
/// the assertion also exempts the app from App Nap, which would otherwise
/// throttle the in-process VM.
final class SleepAssertion {
    private let reason: String
    private var token: NSObjectProtocol?

    init(reason: String) {
        self.reason = reason
    }

    /// Starts preventing sleep. Holding one assertion is enough; a second
    /// `begin()` without an `end()` in between does nothing.
    func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: reason)
    }

    /// Lets the Mac sleep again. Safe to call when nothing is held.
    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }

    deinit { end() }
}
