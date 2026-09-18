import Foundation

/// How the guest reaches the network. Chosen in the Settings window,
/// persisted in UserDefaults, and read by `NetworkVMFeature` when the VM
/// starts.
enum NetworkSettings {
    private static let modeKey = "NetworkMode"

    enum Mode: String, CaseIterable {
        /// A device of its own on the physical LAN, via vmnet's bridged mode.
        /// The default: it's what device discovery needs.
        case bridged

        /// Behind the Mac's own address, via vmnet's shared mode. The
        /// escape hatch for networks that admit the Mac but not a second
        /// device behind it — corporate Wi-Fi, typically — where bridged DHCP
        /// requests go unanswered. Costs LAN discovery and reachability from
        /// other devices.
        case shared

        /// Name for the Settings popup.
        var title: String {
            switch self {
            case .bridged: return "Bridged — on your network"
            case .shared: return "Shared — through the Mac"
            }
        }

        /// What the mode means for Home Assistant, for the caption under the
        /// popup.
        var summary: String {
            switch self {
            case .bridged:
                return "Home Assistant is a device on your network with an address from "
                    + "your router, which is what finding devices (mDNS, SSDP, Matter) needs. "
                    + "Some networks refuse a second device behind the Mac — corporate Wi-Fi, "
                    + "typically; the menu says so when that happens."
            case .shared:
                return "Home Assistant reaches the network through the Mac and is reachable "
                    + "only from it. Works where bridging doesn't, but Home Assistant can't "
                    + "find devices on your network and other devices can't reach it."
            }
        }
    }

    /// The mode the guest starts with. Anything stored that isn't a known
    /// mode falls back to bridged.
    static var mode: Mode {
        get {
            guard let stored = UserDefaults.standard.string(forKey: modeKey),
                  let mode = Mode(rawValue: stored) else { return .bridged }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }
}
