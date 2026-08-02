import Foundation
import Virtualization

/// Puts the guest on the physical LAN, bridged through vmnet.
///
/// Home Assistant's discovery — mDNS, SSDP, Matter — only works if the guest
/// is a first-class device on the same network as the things it talks to, so
/// this is a bridge rather than the NAT that Virtualization.framework offers
/// out of the box. `VmnetBridge` does the work; the feature owns its lifetime.
final class NetworkVMFeature: VMFeature {
    /// The live bridge while the VM runs. A fresh one per start: the vmnet
    /// interface it holds is tied to a single run of the guest.
    private var bridge: VmnetBridge?

    func configure(_ configuration: VZVirtualMachineConfiguration,
                   in context: VMFeatureContext) throws {
        let bridge = VmnetBridge()
        // Stored before anything can throw, so a failure further along this
        // start still gets the interface torn down.
        self.bridge = bridge
        let connection = try bridge.start(stateDirectory: context.stateDirectory)

        let device = VZVirtioNetworkDeviceConfiguration()
        device.macAddress = connection.macAddress
        device.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: connection.fileHandle)
        configuration.networkDevices.append(device)
    }

    func tearDown() {
        bridge?.stop()
        bridge = nil
    }
}
