import Foundation
import Virtualization
import os

/// Makes the guest act on the host's request to shut down.
///
/// `VZVirtualMachine.requestStop()` reaches the guest as a short press of a
/// power button, and Home Assistant OS's generic images are built to ignore
/// exactly that: on the bare-metal boards they're meant for, a bumped button
/// mustn't take the house down, so only a long press powers off. The host
/// has no long press to send and no other way into the guest that doesn't
/// need credentials, so the guest is handed a logind drop-in that turns the
/// short press back on. Without it every stop — Quit, Shut Down, a logout —
/// waits out the grace period and pulls the plug.
///
/// The drop-in travels the way the shared folder does: a read-only virtiofs
/// share, mounted at boot over logind's drop-in directory by way of the
/// kernel command line. The mount lands under `/run` rather than `/etc`: it's
/// tmpfs from the first moment of boot, so the mount point can always be
/// made, and nothing is left behind in the guest when the share is gone.
final class PowerButtonVMFeature: VMFeature {
    /// virtiofs tag the drop-in directory is published under.
    static let tag = "haos-logind"

    /// Where logind looks for drop-ins, besides `/etc/systemd/logind.conf.d`.
    static let guestDirectory = "/run/systemd/logind.conf.d"

    /// Identifies our kernel parameter in the guest's command line, whatever
    /// directory an earlier version mounted the share at.
    static let kernelParameterPrefix = "systemd.mount-extra=\(tag):"

    /// Mounts the share early enough that logind reads it on its way up; the
    /// mount is ordered before `local-fs.target`, logind after it. `nofail`
    /// keeps a guest that boots without the share from stalling.
    static let kernelParameter = "\(kernelParameterPrefix)\(guestDirectory):virtiofs:ro,nofail"

    /// The one file in the share. Overrides only the short press; the long
    /// press keeps doing what the image says.
    private static let dropIn = """
        # Added by HAOS.app so the guest powers off when the host asks it to.
        [Login]
        HandlePowerKey=poweroff

        """

    private static func directory(in context: VMFeatureContext) -> URL {
        context.stateDirectory.appendingPathComponent("logind.conf.d", isDirectory: true)
    }

    /// Writes the drop-in afresh and puts the kernel command line in sync.
    /// A failure is logged rather than raised: a shutdown that has to fall
    /// back to the grace period is a poor reason to leave Home Assistant
    /// down, and both steps are attempted again on the next start.
    func prepare(in context: VMFeatureContext) {
        do {
            let directory = Self.directory(in: context)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.dropIn.write(to: directory.appendingPathComponent("haos.conf"),
                                  atomically: true, encoding: .utf8)
            try GuestBootConfig.setKernelParameter(
                Self.kernelParameter,
                replacingPrefix: Self.kernelParameterPrefix,
                imagePath: context.diskImageURL.path)
        } catch {
            log.error("Could not set up the guest's power button: \(error.localizedDescription, privacy: .public)")
        }
    }

    func configure(_ configuration: VZVirtualMachineConfiguration,
                   in context: VMFeatureContext) throws {
        let directory = Self.directory(in: context)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let device = VZVirtioFileSystemDeviceConfiguration(tag: Self.tag)
        device.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: directory, readOnly: true))
        configuration.directorySharingDevices.append(device)
    }
}
