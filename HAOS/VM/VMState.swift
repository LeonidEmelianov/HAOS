import Foundation

/// The lifecycle of the Home Assistant VM, as shown in the menu bar.
enum VMState {
    /// First launch: the disk image is being downloaded and unpacked.
    /// `progress` is ready-to-display text such as "Downloading image… 42%".
    case provisioning(progress: String)

    /// The VM is booting.
    case starting

    /// The guest is up and running.
    case running

    /// A graceful shutdown was requested and the guest is powering off.
    case stopping

    /// No VM is running. `error` describes an abnormal guest stop;
    /// nil means the guest shut down cleanly (or never started).
    case stopped(error: String?)

    /// The VM could not be started (download, configuration or boot failure).
    /// `error` describes why, for the menu's status line.
    case failed(error: String?)

    /// Text for the status line at the top of the menu.
    var menuTitle: String {
        switch self {
        case .provisioning(let progress): return progress
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        case .stopped(let error?): return "Stopped (error: \(error))"
        case .stopped(nil): return "Stopped"
        case .failed(let error?): return "Failed: \(error)"
        case .failed(nil): return "Failed"
        }
    }

    /// True once the VM is fully stopped, cleanly or not.
    var isStopped: Bool {
        if case .stopped = self { return true }
        return false
    }

    /// True while the guest is up.
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// True when nothing is in flight — the disk image isn't being
    /// downloaded or unpacked and no VM is starting, running or stopping —
    /// so a new start may be requested.
    var canStart: Bool {
        switch self {
        case .stopped, .failed: return true
        case .provisioning, .starting, .running, .stopping: return false
        }
    }
}
