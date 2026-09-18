import Foundation

/// The lifecycle of the Home Assistant VM, as shown in the menu bar.
enum VMState {
    /// First launch: the disk image is being downloaded and unpacked.
    /// `progress` is ready-to-display text such as "Downloading image… 42%".
    case provisioning(progress: String)

    /// The VM is booting.
    case starting

    /// The guest is up. `homeAssistant` is how far Home Assistant itself has
    /// got: the guest is on the network well before the web UI answers.
    /// `problem`, when set, is something a feature noticed that keeps the
    /// guest from working and the user can act on — bridged DHCP requests
    /// going unanswered, say — and takes over the status line.
    case running(homeAssistant: HomeAssistantProgress, problem: String? = nil)

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
        case .running(_, let problem?): return "Running — \(problem)"
        case .running(.installing, nil):
            return "Running — installing Home Assistant (first start; takes several minutes)"
        case .running(.starting, nil): return "Running — starting Home Assistant…"
        case .running(.ready, nil): return "Running"
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

    /// True while the guest is up, whether or not Home Assistant is yet.
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

/// What the guest has to show for itself once it's up. The Supervisor starts
/// Home Assistant some time after the guest boots, and on a first boot it has
/// to download Home Assistant before it can start it — minutes during which
/// the guest's console drops into an "emergency" shell that looks like a
/// failure and isn't.
enum HomeAssistantProgress {
    /// First boot: the Supervisor is downloading Home Assistant's containers.
    case installing

    /// The Supervisor is bringing Home Assistant up.
    case starting

    /// The web UI answers.
    case ready
}
