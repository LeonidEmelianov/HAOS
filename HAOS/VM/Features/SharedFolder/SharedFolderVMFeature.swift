import Foundation
import Virtualization

/// Shares a folder from the Mac with the guest over virtiofs.
///
/// Two halves have to agree for that to work: the host offers the folder as a
/// virtiofs device, and the guest mounts it. Both are driven from
/// `SharedFolderSettings`, so they can't drift apart.
final class SharedFolderVMFeature: VMFeature {
    /// Puts the guest's kernel command line in sync with the shared-folder
    /// setting. Offering the virtiofs device isn't enough — nothing in Home
    /// Assistant OS mounts it on its own, and its read-only root filesystem
    /// leaves the kernel command line as the only durable place to say so.
    ///
    /// A failure here is logged rather than raised: not mounting the share is
    /// a poor reason to leave Home Assistant down. The edit is attempted again
    /// on the next start.
    func prepare(in context: VMFeatureContext) {
        do {
            try GuestBootConfig.setKernelParameter(
                SharedFolderSettings.activeFolderURL == nil
                    ? nil : SharedFolderSettings.kernelParameter,
                replacingPrefix: SharedFolderSettings.kernelParameterPrefix,
                imagePath: context.diskImageURL.path)
        } catch {
            NSLog("Could not update the guest's shared-folder mount: %@",
                  error.localizedDescription)
        }
    }

    /// Adds the virtiofs device carrying the shared folder, or nothing when
    /// there's nothing to share. The folder is recreated if the one the user
    /// picked has since been moved or deleted — an empty share beats a VM that
    /// won't start.
    func configure(_ configuration: VZVirtualMachineConfiguration,
                   in context: VMFeatureContext) throws {
        guard let url = SharedFolderSettings.activeFolderURL else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let device = VZVirtioFileSystemDeviceConfiguration(tag: SharedFolderSettings.tag)
        device.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: url, readOnly: false))
        configuration.directorySharingDevices.append(device)
    }
}
