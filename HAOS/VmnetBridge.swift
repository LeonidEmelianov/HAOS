import Foundation
import SystemConfiguration
import Virtualization
import vmnet

/// Bridged networking via vmnet.framework, in-process.
///
/// vmnet's bridged mode historically needed root or the Apple-gated
/// com.apple.vm.networking entitlement; macOS 26 lifted that for apps with
/// the virtualization entitlement (the first start triggers a one-time
/// system authorization prompt), so the app can use vmnet directly instead
/// of delegating to an external helper process.
/// VZFileHandleNetworkDeviceAttachment still wants a datagram socket, so we
/// keep a socketpair and pump raw ethernet frames between vmnet and our end
/// of it. The guest becomes a first-class device on the physical LAN — real
/// router DHCP, link-local IPv6 and multicast — which is what Matter and
/// mDNS/SSDP discovery need.
final class VmnetBridge {
    /// MAC assigned by vmnet, derived from the persisted interface UUID.
    /// The guest NIC must use exactly this address or vmnet drops its frames.
    private(set) var macAddress: VZMACAddress?

    /// All vmnet callbacks, socket reads and the shared packet buffer are
    /// confined to this serial queue.
    private let queue = DispatchQueue(label: "VmnetBridge")
    private var interface: interface_ref?
    private var hostSocket: Int32 = -1
    private var socketSource: DispatchSourceRead?
    private var packetBuffer: UnsafeMutableRawPointer?
    private var maxPacketSize = 0

    /// Starts a vmnet interface bridged onto the physical LAN and returns
    /// the VM's end of the socketpair for VZFileHandleNetworkDeviceAttachment.
    func start(stateDirectory: URL) throws -> FileHandle {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw Self.error("socketpair() failed: \(String(cString: strerror(errno)))")
        }
        let vmSide = fds[0], hostSide = fds[1]
        // Default socket buffers are too small for virtio traffic and drop frames.
        var bufferSize = Int32(1024 * 1024)
        for fd in fds {
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        }
        // A stalled guest must never block the vmnet callback queue; dropping
        // frames when the buffer is full is normal ethernet behavior.
        _ = fcntl(hostSide, F_SETFL, fcntl(hostSide, F_GETFL) | O_NONBLOCK)

        do {
            try startInterface(interfaceID: interfaceID(stateDirectory: stateDirectory))
        } catch {
            close(vmSide)
            close(hostSide)
            throw error
        }

        hostSocket = hostSide
        packetBuffer = .allocate(byteCount: maxPacketSize, alignment: MemoryLayout<UInt>.alignment)

        vmnet_interface_set_event_callback(interface!, .VMNET_INTERFACE_PACKETS_AVAILABLE, queue) {
            [weak self] _, _ in self?.forwardToGuest()
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: hostSide, queue: queue)
        source.setEventHandler { [weak self] in self?.forwardToHost() }
        source.setCancelHandler { close(hostSide) }
        source.resume()
        socketSource = source

        return FileHandle(fileDescriptor: vmSide, closeOnDealloc: true)
    }

    /// Stops the vmnet interface and releases the socketpair and buffers.
    /// Safe to call more than once; blocks briefly while vmnet shuts down.
    func stop() {
        socketSource?.cancel() // the cancel handler closes hostSocket
        socketSource = nil
        hostSocket = -1
        if let interface {
            let done = DispatchSemaphore(value: 0)
            vmnet_stop_interface(interface, queue) { _ in done.signal() }
            done.wait() // also drains in-flight forwarding blocks on `queue`
        }
        interface = nil
        packetBuffer?.deallocate()
        packetBuffer = nil
    }

    // MARK: - vmnet interface

    /// Brings up the bridged vmnet interface and records the MAC address and
    /// maximum packet size it hands back.
    private func startInterface(interfaceID: UUID) throws {
        let desc = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, UInt64(operating_modes_t.VMNET_BRIDGED_MODE.rawValue))
        xpc_dictionary_set_string(desc, vmnet_shared_interface_name_key, try Self.sharedInterfaceName())
        var uuid = interfaceID.uuid
        withUnsafeBytes(of: &uuid) {
            xpc_dictionary_set_uuid(desc, vmnet_interface_id_key,
                                    $0.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }

        let done = DispatchSemaphore(value: 0)
        var status = vmnet_return_t.VMNET_FAILURE
        var mac: VZMACAddress?
        var packetSize = 0
        let interface = vmnet_start_interface(desc, queue) { result, params in
            status = result
            if let params {
                if let cString = xpc_dictionary_get_string(params, vmnet_mac_address_key) {
                    mac = VZMACAddress(string: String(cString: cString))
                }
                packetSize = Int(xpc_dictionary_get_uint64(params, vmnet_max_packet_size_key))
            }
            done.signal()
        }
        guard let interface else {
            throw Self.error("vmnet_start_interface() rejected the configuration")
        }
        // Bridged start can block indefinitely: on Macs with the N1 Wi-Fi
        // chip (M5 generation), macOS 26.4–26.5 cannot bridge VMs over
        // Wi-Fi at all and vmnet_start_interface never completes — for any
        // app, even as root. Surface an error instead of hanging forever.
        guard done.wait(timeout: .now() + 60) != .timedOut else {
            throw Self.error("bridged networking did not start — macOS 26 cannot bridge over Wi-Fi on this Mac (N1 Wi-Fi chip); connect a USB/Thunderbolt ethernet adapter and try again")
        }
        guard status == .VMNET_SUCCESS, let mac, packetSize > 0 else {
            throw Self.error("vmnet failed to start bridged interface: \(Self.describe(status))")
        }
        self.interface = interface
        self.macAddress = mac
        self.maxPacketSize = packetSize
    }

    /// vmnet → guest: drain everything vmnet has queued, one datagram per
    /// ethernet frame. Runs on `queue`.
    private func forwardToGuest() {
        guard let interface, let buffer = packetBuffer else { return }
        while true {
            var iov = iovec(iov_base: buffer, iov_len: maxPacketSize)
            let frameSize = withUnsafeMutablePointer(to: &iov) { iovPointer -> Int in
                var packet = vmpktdesc(vm_pkt_size: maxPacketSize, vm_pkt_iov: iovPointer,
                                       vm_pkt_iovcnt: 1, vm_flags: 0)
                var count: Int32 = 1
                guard vmnet_read(interface, &packet, &count) == .VMNET_SUCCESS, count > 0 else { return 0 }
                return packet.vm_pkt_size
            }
            guard frameSize > 0 else { return }
            _ = send(hostSocket, buffer, frameSize, 0) // EAGAIN drops the frame
        }
    }

    /// guest → vmnet: drain the socket. Runs on `queue`.
    private func forwardToHost() {
        guard let interface, let buffer = packetBuffer else { return }
        while true {
            let size = recv(hostSocket, buffer, maxPacketSize, 0)
            guard size > 0 else { return }
            var iov = iovec(iov_base: buffer, iov_len: size)
            withUnsafeMutablePointer(to: &iov) { iovPointer in
                var packet = vmpktdesc(vm_pkt_size: size, vm_pkt_iov: iovPointer,
                                       vm_pkt_iovcnt: 1, vm_flags: 0)
                var count: Int32 = 1
                _ = vmnet_write(interface, &packet, &count)
            }
        }
    }

    /// The physical interface to bridge onto. A wired adapter (the Mac has no
    /// built-in ethernet, so a Thunderbolt/USB one may come and go) is
    /// preferred over Wi-Fi; within a class, the default-route interface
    /// wins. vmnet only lists interfaces that are up, so an unplugged
    /// adapter naturally drops out of consideration.
    private static func sharedInterfaceName() throws -> String {
        var bridgeable: [String] = []
        if let list = vmnet_copy_shared_interface_list() {
            for index in 0..<xpc_array_get_count(list) {
                if let name = xpc_array_get_string(list, index) {
                    bridgeable.append(String(cString: name))
                }
            }
        }
        var wifi = Set<String>()
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            if SCNetworkInterfaceGetInterfaceType(interface) == kSCNetworkInterfaceTypeIEEE80211,
               let bsdName = SCNetworkInterfaceGetBSDName(interface) {
                wifi.insert(bsdName as String)
            }
        }
        var primary: String?
        if let store = SCDynamicStoreCreate(nil, "VmnetBridge" as CFString, nil, nil),
           let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            primary = global["PrimaryInterface"] as? String
        }
        let wired = bridgeable.filter { !wifi.contains($0) }
        for candidates in [wired, bridgeable] where !candidates.isEmpty {
            if let primary, candidates.contains(primary) { return primary }
            return candidates[0]
        }
        throw error("no physical interface available for bridged networking")
    }

    // MARK: - Support

    /// A persisted random UUID identifies the vmnet interface across runs,
    /// which keeps the assigned MAC — and thus the router's DHCP lease — stable.
    private func interfaceID(stateDirectory: URL) -> UUID {
        let url = stateDirectory.appendingPathComponent("BridgedInterfaceID")
        if let saved = try? String(contentsOf: url, encoding: .utf8),
           let id = UUID(uuidString: saved.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return id
        }
        let id = UUID()
        try? id.uuidString.write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    private static func describe(_ status: vmnet_return_t) -> String {
        switch status {
        case .VMNET_FAILURE: return "general failure"
        case .VMNET_MEM_FAILURE: return "out of memory"
        case .VMNET_INVALID_ARGUMENT: return "invalid argument (is the shared interface up?)"
        case .VMNET_SETUP_INCOMPLETE: return "setup incomplete"
        case .VMNET_INVALID_ACCESS: return "not permitted (bridged vmnet needs macOS 26 or root)"
        case .VMNET_SHARING_SERVICE_BUSY: return "sharing service busy"
        default: return "status \(status.rawValue)"
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "VmnetBridge", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
