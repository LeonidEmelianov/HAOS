import Foundation
import Virtualization

/// The machine itself: how many CPUs and how much memory the guest gets. Both
/// are user-adjustable in the Settings window, persisted in UserDefaults, and
/// take effect the next time the VM starts.
///
/// Settings belonging to one capability live with that capability instead —
/// see `SharedFolderSettings`.
enum VMSettings {
    private static let cpuCountKey = "VMCPUCount"
    private static let memorySizeKey = "VMMemorySize"

    /// CPU cores given to the guest when the user hasn't chosen otherwise.
    static let defaultCPUCount = 2

    /// Memory given to the guest when the user hasn't chosen otherwise.
    static let defaultMemorySize: UInt64 = 4 * 1024 * 1024 * 1024 // 4 GiB

    /// HAOS needs headroom for the Supervisor and add-on containers; below
    /// 2 GiB the guest OOMs during onboarding.
    static let minimumMemorySize: UInt64 = 2 * 1024 * 1024 * 1024 // 2 GiB

    /// Host limits from Virtualization.framework, queried at read time so a
    /// value saved on one machine can't produce an invalid configuration on
    /// another.
    static var allowedCPUCounts: ClosedRange<Int> {
        VZVirtualMachineConfiguration.minimumAllowedCPUCount
            ... VZVirtualMachineConfiguration.maximumAllowedCPUCount
    }

    /// Memory sizes the host accepts, floored at `minimumMemorySize`.
    static var allowedMemorySizes: ClosedRange<UInt64> {
        max(minimumMemorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
            ... VZVirtualMachineConfiguration.maximumAllowedMemorySize
    }

    /// The guest's CPU count, clamped to what the host allows.
    static var cpuCount: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: cpuCountKey)
            let value = stored > 0 ? stored : defaultCPUCount
            return min(max(value, allowedCPUCounts.lowerBound), allowedCPUCounts.upperBound)
        }
        set { UserDefaults.standard.set(newValue, forKey: cpuCountKey) }
    }

    /// The guest's memory size in bytes, clamped to what the host allows.
    static var memorySize: UInt64 {
        get {
            let stored = (UserDefaults.standard.object(forKey: memorySizeKey) as? NSNumber)?
                .uint64Value ?? defaultMemorySize
            return min(max(stored, allowedMemorySizes.lowerBound), allowedMemorySizes.upperBound)
        }
        set { UserDefaults.standard.set(NSNumber(value: newValue), forKey: memorySizeKey) }
    }
}
