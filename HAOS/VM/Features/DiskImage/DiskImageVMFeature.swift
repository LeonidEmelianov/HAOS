import Foundation
import Virtualization

/// The guest's disk. Downloads the Home Assistant OS image on first launch,
/// grows it to the full virtual disk size, and attaches it to the machine.
final class DiskImageVMFeature: VMFeature {
    /// Virtual disk size. HAOS ships a ~6 GiB image and expands its data
    /// partition to fill the disk on boot; without growing the image first,
    /// the data partition is too small for the Supervisor containers and the
    /// HA CLI never comes up. The file stays sparse on APFS, so this costs
    /// only what the guest actually writes.
    static let diskSize: UInt64 = 48 * 1024 * 1024 * 1024 // 48 GiB

    /// First launch: no disk image yet — fetch the latest HAOS release. The
    /// download blocks the start (which is already off the main thread) and
    /// reports its progress to the menu's status line.
    func prepare(in context: VMFeatureContext) throws {
        guard !FileManager.default.fileExists(atPath: context.diskImageURL.path) else { return }
        try ImageDownloader(destination: context.diskImageURL)
            .downloadLatestImage(progress: context.reportProgress)
    }

    func configure(_ configuration: VZVirtualMachineConfiguration,
                   in context: VMFeatureContext) throws {
        let url = context.diskImageURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HAOSError("Disk image not found at \(url.path)")
        }
        try grow(url, to: Self.diskSize)
        let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: false)
        configuration.storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
    }

    /// Extends the raw image file to `size` (the equivalent of
    /// `qemu-img resize` for raw images). Never shrinks: a user-grown image
    /// larger than the default is left alone.
    private func grow(_ url: URL, to size: UInt64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        guard try handle.seekToEnd() < size else { return }
        try handle.truncate(atOffset: size)
    }
}
