import Foundation

/// How big the guest's virtual disk is. Chosen in the Settings window,
/// persisted in UserDefaults, and applied by `DiskImageVMFeature`: the image is
/// grown to this size when the user asks, if the VM is stopped, and otherwise
/// the next time it starts.
enum DiskImageSettings {
    private static let sizeKey = "VMDiskSize"

    static let gibibyte: UInt64 = 1 << 30

    /// Virtual disk size when the user hasn't chosen otherwise. HAOS ships a
    /// ~6 GiB image and expands its data partition to fill the disk on boot;
    /// without growing the image first, the data partition is too small for
    /// the Supervisor containers and the HA CLI never comes up. The file stays
    /// sparse on APFS, so this costs only what the guest actually writes.
    static let defaultSize: UInt64 = 48 * gibibyte

    /// Sizes offered in the Settings popup, in GiB.
    static let choicesGiB: [Int] = Array(stride(from: 32, through: 256, by: 16))

    /// The size the image is grown to. Never shrinks the image — a raw disk
    /// can't be cut down without losing the partitions at its end — so a
    /// stored value below the image's current size is simply a no-op.
    static var size: UInt64 {
        get {
            (UserDefaults.standard.object(forKey: sizeKey) as? NSNumber)?.uint64Value
                ?? defaultSize
        }
        set { UserDefaults.standard.set(NSNumber(value: newValue), forKey: sizeKey) }
    }

    /// "48 GB", the way the Settings popup and captions spell a size.
    static func title(for size: UInt64) -> String {
        "\((size + gibibyte - 1) / gibibyte) GB"
    }
}
