import Foundation
import Virtualization

/// Keeps the guest off the Scalable Matrix Extension.
///
/// Apple's M4 and later have SME, Virtualization.framework shows it to the
/// guest, and Linux turns it on — and the guest doesn't survive that. Seen on
/// a first boot of Home Assistant OS 18.3 on an M4 under macOS 27: within two
/// seconds of each other, `systemd-tmpfiles` died of an illegal instruction,
/// a udev worker segfaulted, and ext4 rejected block bitmaps whose checksums
/// were fine on disk while writing back one that wasn't. The boot then sat on
/// a job that never ended. The M4 implements SME2 without the non-streaming
/// SVE that code selected on the SME flag tends to assume, and the same
/// combination has taken down OpenSSL, OpenBLAS, the JVM and .NET in guests
/// on M4 hosts.
///
/// The host can't hide the feature — the platform configuration has no CPU
/// controls — so the guest's kernel is told to leave it alone: `arm64.nosme`
/// on the kernel command line, which reaches the guest the way the
/// shared-folder and power-button parameters do. That puts an M4 guest back
/// to what it is on an M1–M3. Hosts without SME are left alone: the guest
/// never sees the feature there, and attaching the image costs a second or
/// two per start.
final class NoSMEVMFeature: VMFeature {
    /// Takes no value, so it is its own prefix.
    static let kernelParameter = "arm64.nosme"

    /// Whether the Mac's CPU has SME. The key is missing on macOS releases
    /// that predate the feature, which reads as no.
    static var hostHasSME: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm.FEAT_SME", &value, &size, nil, 0) == 0 && value != 0
    }

    /// Unlike the shared folder and the power button, a failure here fails
    /// the start: a guest booted with SME corrupts its data partition within
    /// seconds, and not starting is the safer of the two outcomes.
    func prepare(in context: VMFeatureContext) throws {
        guard Self.hostHasSME else { return }
        do {
            try GuestBootConfig.setKernelParameter(Self.kernelParameter,
                                                   replacingPrefix: Self.kernelParameter,
                                                   imagePath: context.diskImageURL.path)
        } catch {
            throw HAOSError("Could not disable SME in the guest's kernel, which an M4 guest "
                            + "needs to boot without corrupting its disk: \(error.localizedDescription)")
        }
    }

    /// Nothing to add to the machine: the CPU it gets can't be shaped from here.
    func configure(_ configuration: VZVirtualMachineConfiguration,
                   in context: VMFeatureContext) throws {}
}
