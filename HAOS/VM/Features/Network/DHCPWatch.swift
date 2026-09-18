import Foundation
import Virtualization

/// Notices when the guest's DHCP requests go unanswered.
///
/// A bridged guest on a network that admits the Mac but not a second device
/// behind it — corporate Wi-Fi with its per-client DHCP policing, typically —
/// boots fine, sends DHCP Discovers forever and never gets an Offer. Nothing
/// on the host fails: the interface is up and frames flow. The guest just
/// never gets an address, and Home Assistant's own diagnosis is a page on a
/// web UI nobody can reach. The bridge already sees every frame, so this is
/// the one place that can tell.
///
/// Only frames whose BOOTP client address is the guest's count: with MAC NAT
/// the guest also receives the LAN's broadcast Offers meant for other
/// clients, which would otherwise look like answers.
///
/// Everything here runs on the bridge's queue.
final class DHCPWatch {
    enum Outcome {
        /// Requests have gone unanswered for `timeout`.
        case unanswered
        /// A reply arrived (after `unanswered` was reported, or after a
        /// later lapse).
        case answered
    }

    /// How long requests may go unanswered before that is reported. A DHCP
    /// server answers within a second; NetworkManager in the guest resends
    /// every few seconds, so a healthy network never gets near this.
    static let timeout: TimeInterval = 30

    private let guestMAC: [UInt8]
    private let queue: DispatchQueue
    private let onChange: (Outcome) -> Void

    /// The check scheduled by the first unanswered request; nil while
    /// nothing is outstanding.
    private var pendingCheck: DispatchWorkItem?
    private var reportedUnanswered = false

    init(guestMAC: VZMACAddress, queue: DispatchQueue, onChange: @escaping (Outcome) -> Void) {
        let octets = guestMAC.ethernetAddress.octet
        self.guestMAC = [octets.0, octets.1, octets.2, octets.3, octets.4, octets.5]
        self.queue = queue
        self.onChange = onChange
    }

    /// A frame the guest is sending.
    func sawFrameFromGuest(_ frame: UnsafeRawPointer, length: Int) {
        guard pendingCheck == nil,
              Self.isDHCP(frame, length: length, from: 68, to: 67, clientMAC: guestMAC) else { return }
        let check = DispatchWorkItem { [weak self] in
            guard let self, !self.reportedUnanswered else { return }
            self.reportedUnanswered = true
            self.onChange(.unanswered)
        }
        pendingCheck = check
        queue.asyncAfter(deadline: .now() + Self.timeout, execute: check)
    }

    /// A frame being delivered to the guest.
    func sawFrameToGuest(_ frame: UnsafeRawPointer, length: Int) {
        guard let check = pendingCheck,
              Self.isDHCP(frame, length: length, from: 67, to: 68, clientMAC: guestMAC) else { return }
        check.cancel()
        pendingCheck = nil
        if reportedUnanswered {
            reportedUnanswered = false
            onChange(.answered)
        }
    }

    /// Drops the scheduled check; nothing is reported after this.
    func cancel() {
        pendingCheck?.cancel()
        pendingCheck = nil
    }

    /// Whether the frame is an IPv4 UDP datagram between the given ports
    /// carrying a BOOTP message for `clientMAC`. Offsets are the plain
    /// Ethernet II + IPv4 + UDP + BOOTP layout; anything shorter or
    /// different is simply not DHCP.
    private static func isDHCP(_ frame: UnsafeRawPointer, length: Int,
                               from sourcePort: UInt16, to destinationPort: UInt16,
                               clientMAC: [UInt8]) -> Bool {
        let bytes = UnsafeRawBufferPointer(start: frame, count: length)
        guard length >= 14 + 20, bytes[12] == 0x08, bytes[13] == 0x00,
              bytes[14] >> 4 == 4, bytes[23] == 17 else { return false }
        let udp = 14 + Int(bytes[14] & 0x0f) * 4
        let bootp = udp + 8
        // op through chaddr; the fields before chaddr aren't needed, only its
        // offset within the message.
        let chaddr = bootp + 28
        guard length >= chaddr + 6,
              UInt16(bytes[udp]) << 8 | UInt16(bytes[udp + 1]) == sourcePort,
              UInt16(bytes[udp + 2]) << 8 | UInt16(bytes[udp + 3]) == destinationPort
        else { return false }
        return (0..<6).allSatisfy { bytes[chaddr + $0] == clientMAC[$0] }
    }
}
