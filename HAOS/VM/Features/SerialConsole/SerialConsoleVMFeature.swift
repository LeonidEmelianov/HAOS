import Foundation
import Virtualization
import os

/// The Home Assistant CLI on a serial line, reachable from the Mac through a
/// Unix socket — for a terminal, or a script, rather than the console window.
///
/// Nothing else on the Mac can reach the CLI: the guest has no SSH until an
/// add-on provides one, and the Supervisor's API listens only inside the
/// guest. A virtio console shows up in the guest as `hvc0`, and Home
/// Assistant OS already ships the unit that runs its CLI on a terminal —
/// `ha-cli@`, enabled for `tty1` alone — so the kernel command line asks
/// systemd for a second instance on `hvc0`. systemd would also put a login
/// prompt on a virtualizer's console of its own accord, and the two would
/// fight over the line, so that getty is masked.
///
/// The console is deliberately not a kernel console (`console=hvc0`): the
/// last one named becomes `/dev/console`, which would move the boot messages
/// out of the console window, and the CLI's output would be interleaved with
/// the kernel's.
final class SerialConsoleVMFeature: VMFeature {
    /// Both take no value, so each is its own prefix.
    static let kernelParameters = [
        "systemd.wants=ha-cli@hvc0.service",
        "systemd.mask=serial-getty@hvc0.service",
    ]

    static func socketURL(in context: VMFeatureContext) -> URL {
        context.stateDirectory.appendingPathComponent("console.sock")
    }

    private var relay: ConsoleRelay?

    /// A failure is logged rather than raised: the console window still
    /// gives the CLI to anyone at the Mac, and the edit is attempted again on
    /// the next start.
    func prepare(in context: VMFeatureContext) {
        do {
            try GuestBootConfig.setKernelParameters(
                Self.kernelParameters.map { ($0, $0) },
                imagePath: context.diskImageURL.path)
        } catch {
            log.error("Could not put the CLI on the serial console: \(error.localizedDescription, privacy: .public)")
        }
    }

    func configure(_ configuration: VZVirtualMachineConfiguration,
                   in context: VMFeatureContext) throws {
        let relay = ConsoleRelay(socketURL: Self.socketURL(in: context))
        relay.start()
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = relay.attachment
        configuration.serialPorts.append(port)
        self.relay = relay
    }

    func tearDown() {
        relay?.stop()
        relay = nil
    }
}
