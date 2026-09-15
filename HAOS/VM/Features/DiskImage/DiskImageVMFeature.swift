import Foundation
import Virtualization

/// The guest's disk. Downloads the Home Assistant OS image on first launch,
/// grows it to the chosen virtual disk size, and attaches it to the machine.
final class DiskImageVMFeature: VMFeature {
    /// Where the Home Assistant OS disk image lives on the host.
    static let imageURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/HAOS/HAOS.img")

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
        try Self.grow(url, to: DiskImageSettings.size)
        let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: false)
        configuration.storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
    }

    // MARK: - The image file

    /// Extends the raw image file to `size` (the equivalent of
    /// `qemu-img resize` for raw images). Never shrinks: a user-grown image
    /// larger than the setting is left alone. Home Assistant OS expands its
    /// data partition into the new space on its next boot.
    ///
    /// Only for an image no VM is using: growing the file under a running
    /// guest does it no harm, but the guest wouldn't see the space either.
    static func grow(_ url: URL, to size: UInt64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        guard try handle.seekToEnd() < size else { return }
        try handle.truncate(atOffset: size)
    }

    /// The image's virtual size — its length, as the guest sees it — or nil
    /// before the first launch has downloaded one.
    static func currentSize(of url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64
    }

    /// The biggest the image could ever fill on this Mac: what's free on its
    /// volume plus what it already occupies there. The file is sparse, so
    /// what it occupies is usually far less than its size; the difference is
    /// space the guest has been promised but the Mac hasn't given yet.
    static func maximumSize(for url: URL) -> UInt64? {
        // The image's directory may not exist before the first launch; the
        // home directory is on the same volume.
        let directory = url.deletingLastPathComponent()
        let volume = FileManager.default.fileExists(atPath: directory.path)
            ? directory : FileManager.default.homeDirectoryForCurrentUser
        guard let free = try? volume.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return nil }
        let occupied = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
            .totalFileAllocatedSize ?? 0
        return UInt64(max(free, 0)) + UInt64(occupied)
    }
}
