import Foundation

/// Which folder on the Mac is shared with the guest, and where the guest puts
/// it. Persisted in UserDefaults by the Settings window; read by
/// `SharedFolderVMFeature` when the VM starts.
enum SharedFolderSettings {
    private static let enabledKey = "SharedFolderEnabled"
    private static let pathKey = "SharedFolderPath"
    private static let guestFolderKey = "SharedFolderGuestPath"

    /// virtiofs tag the share is published under, and the name the guest
    /// mounts it by.
    static let tag = "haos-shared"

    /// Which of the Supervisor's directories the share is mounted over inside
    /// the guest. A fixed set, not a free path: the value is spliced into the
    /// guest's kernel command line, and mounting over the wrong directory (the
    /// Home Assistant config, say) would hide the running configuration.
    enum GuestFolder: String, CaseIterable {
        case backup = "/mnt/data/supervisor/backup"
        case media = "/mnt/data/supervisor/media"
        case share = "/mnt/data/supervisor/share"

        /// Name for the Settings popup.
        var title: String {
            switch self {
            case .backup: return "Backups"
            case .media: return "Media"
            case .share: return "Share"
            }
        }

        /// What the folder is good for, for the caption under the popup.
        var summary: String {
            switch self {
            case .backup: return "Home Assistant writes its backups here."
            case .media: return "The folder shows up in Home Assistant's media browser."
            case .share: return "The folder shows up as /share, which add-ons read and write."
            }
        }
    }

    /// Identifies our kernel parameter in the guest's command line, whatever
    /// tag or directory it currently names — `haos-` is our own namespace, so
    /// a share left over from an older version is cleaned up too.
    static let kernelParameterPrefix = "systemd.mount-extra=haos-"

    /// Kernel parameter that has the guest's systemd mount the share at boot,
    /// early enough that Docker and the Supervisor see it. `nofail` keeps a
    /// guest whose share has gone away — sharing turned off, an image moved to
    /// another Mac — from stalling its boot on a mount it can't make.
    static var kernelParameter: String {
        "systemd.mount-extra=\(tag):\(guestFolder.rawValue):virtiofs:rw,nofail"
    }

    /// Whether a folder on the Mac is shared with the guest. Off by default:
    /// turning it on hides whatever the guest already keeps in the directory
    /// the share is mounted over.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// The shared folder's location on the Mac, or nil until the user picks
    /// one. There's no default: which folder to expose to the guest — and
    /// where in the Finder it belongs — is the user's call, not ours.
    static var folderURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: pathKey),
                  !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: pathKey) }
    }

    /// The folder to hand the guest: nil when sharing is off or no folder has
    /// been picked. Both the virtiofs device and the guest's mount come from
    /// this, so they can't disagree.
    static var activeFolderURL: URL? {
        isEnabled ? folderURL : nil
    }

    /// The directory the share is mounted over in the guest. Anything stored
    /// that isn't one of the known directories falls back to the default.
    static var guestFolder: GuestFolder {
        get {
            guard let stored = UserDefaults.standard.string(forKey: guestFolderKey),
                  let folder = GuestFolder(rawValue: stored) else { return .backup }
            return folder
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: guestFolderKey) }
    }
}
