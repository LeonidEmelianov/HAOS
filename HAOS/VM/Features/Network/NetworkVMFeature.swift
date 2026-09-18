import Foundation
import Virtualization
import os

/// Puts the guest on the network — on the physical LAN through a vmnet
/// bridge by default, or behind the Mac's own address when the user asks.
///
/// Home Assistant's discovery — mDNS, SSDP, Matter — only works if the guest
/// is a first-class device on the same network as the things it talks to, so
/// bridged is the default rather than the NAT that Virtualization.framework
/// offers out of the box. `VmnetBridge` does that work; the feature owns its
/// lifetime. Shared mode is for networks that won't have a second device
/// behind the Mac: it's Virtualization.framework's NAT attachment, and needs
/// nothing from the host.
final class NetworkVMFeature: VMFeature {
    /// The live bridge while the VM runs bridged. A fresh one per start: the
    /// vmnet interface it holds is tied to a single run of the guest.
    private var bridge: VmnetBridge?

    func configure(_ configuration: VZVirtualMachineConfiguration,
                   in context: VMFeatureContext) throws {
        let device = VZVirtioNetworkDeviceConfiguration()
        switch NetworkSettings.mode {
        case .bridged:
            let bridge = VmnetBridge()
            // Stored before anything can throw, so a failure further along
            // this start still gets the interface torn down.
            self.bridge = bridge
            let connection = try bridge.start(stateDirectory: context.stateDirectory)
            log.notice("Bridged onto \(connection.hostInterface, privacy: .public)")
            bridge.watchDHCP { outcome in
                switch outcome {
                case .unanswered:
                    context.reportProblem(Self.noDHCPReplyProblem(on: connection.hostInterface))
                case .answered:
                    context.reportProblem(nil)
                }
            }
            device.macAddress = connection.macAddress
            device.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: connection.fileHandle)
        case .shared:
            log.notice("Shared networking through the Mac")
            device.macAddress = sharedMACAddress(stateDirectory: context.stateDirectory)
            device.attachment = VZNATNetworkDeviceAttachment()
        }
        configuration.networkDevices.append(device)
    }

    func tearDown() {
        bridge?.stop()
        bridge = nil
    }

    /// What the menu says when the bridged guest's DHCP requests go
    /// unanswered. The guest can't say it: its own diagnosis is a page on a
    /// web UI that has no address to be reached at.
    private static func noDHCPReplyProblem(on hostInterface: String) -> String {
        "no DHCP reply on \(hostInterface); this network may not allow bridging — "
            + "try Shared networking in Settings"
    }

    /// A persisted random MAC for shared mode, so the address vmnet's DHCP
    /// hands out stays the same across restarts, the way the persisted
    /// interface ID keeps the bridged MAC stable.
    private func sharedMACAddress(stateDirectory: URL) -> VZMACAddress {
        let url = stateDirectory.appendingPathComponent("SharedNetworkMACAddress")
        if let saved = try? String(contentsOf: url, encoding: .utf8),
           let address = VZMACAddress(string: saved.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return address
        }
        let address = VZMACAddress.randomLocallyAdministered()
        try? address.string.write(to: url, atomically: true, encoding: .utf8)
        return address
    }
}
