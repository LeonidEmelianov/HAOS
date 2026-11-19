import Foundation

/// Which folder on the Mac is shared with the guest, and where the guest puts
/// it. Persisted in UserDefaults by the Settings window; read by
/// `SharedFolderVMFeature` when the VM starts.
enum SharedFolderSettings {
    struct Snapshot {
        let folderURL = SharedFolderSettings.activeFolderURL
        let readOnly = SharedFolderSettings.isReadOnly
        let guestFolder = SharedFolderSettings.guestFolder

        /// Kernel parameter that has the guest's systemd mount the share at
        /// boot, early enough that Docker and the Supervisor see it. `nofail`
        /// keeps a guest whose share has gone away — sharing turned off, an
        /// image moved to another Mac — from stalling its boot on a mount it
        /// can't make. Nil when nothing is shared.
        var kernelParameter: String? {
            guard folderURL != nil else { return nil }
            let access = readOnly ? "ro" : "rw"
            return "\(SharedFolderSettings.kernelParameterPrefix)\(guestFolder.rawValue):virtiofs:\(access),nofail"
        }
    }

    private static let enabledKey = "SharedFolderEnabled"
    private static let pathKey = "SharedFolderPath"
    private static let guestFolderKey = "SharedFolderGuestPath"
    private static let readOnlyKey = "SharedFolderReadOnly"

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

        /// Whether the read-only choice applies to this folder. Backups are
        /// Home Assistant's own to write — a scheduled backup into a read-only
        /// share fails with an error every time it runs, and restoring one
        /// unpacks it into a temporary directory next to the .tar — so a
        /// Backups share is always writable. The choice is for folders the
        /// guest only needs to look at.
        var canBeReadOnly: Bool { self != .backup }

        /// What the folder is good for, for the caption under the popup. The
        /// read-only wording is spelled out per folder rather than tacked on as
        /// a sentence: what the guest loses differs — /share it can no longer
        /// write to, media it can still play — and Backups, which can't be
        /// read-only at all, says so right under the disabled checkbox.
        func summary(readOnly: Bool) -> String {
            switch (self, readOnly) {
            case (.backup, _):
                return "Home Assistant writes its backups here and restores from them, "
                    + "so the folder can't be read-only."
            case (.media, false): return "The folder shows up in Home Assistant's media browser."
            case (.media, true):
                return "The folder shows up in Home Assistant's media browser, "
                    + "which plays the files without changing them."
            case (.share, false):
                return "The folder shows up as /share, which add-ons read and write."
            case (.share, true): return "The folder shows up as /share, which add-ons read."
            }
        }
    }

    /// Identifies our kernel parameter in the guest's command line, whatever
    /// directory or access it currently names. The prefix stops at the tag:
    /// other features mount their own `haos-` shares the same way, and each
    /// must leave the others' parameters alone.
    static let kernelParameterPrefix = "systemd.mount-extra=\(tag):"

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

    /// Whether the guest may only read the share. On by default, and read
    /// through `object(forKey:)` because `bool(forKey:)` can't tell an unset
    /// key from a stored `false`: a folder on the Mac is the user's, and the
    /// guest shouldn't get write access to it without being told to. Picking
    /// Backups is that telling: that share is never read-only, whatever is
    /// stored, and the stored choice is left alone so the one made for
    /// another folder survives a detour through Backups.
    static var isReadOnly: Bool {
        get {
            guestFolder.canBeReadOnly
                && (UserDefaults.standard.object(forKey: readOnlyKey) as? Bool ?? true)
        }
        set { UserDefaults.standard.set(newValue, forKey: readOnlyKey) }
    }
}
