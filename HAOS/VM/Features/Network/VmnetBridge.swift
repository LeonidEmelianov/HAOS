import Foundation
import SystemConfiguration
import Virtualization
import vmnet
import os

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
    /// What the guest's NIC needs from a running bridge: the socket to attach
    /// to it, and the MAC address vmnet assigned — frames from any other
    /// address are dropped, so the NIC has to use exactly this one.
    struct Connection {
        let fileHandle: FileHandle
        let macAddress: VZMACAddress
        /// The physical interface the guest is bridged onto, as the user
        /// would recognise it: "Wi-Fi (en0)".
        let hostInterface: String
    }

    /// All vmnet callbacks, socket reads and the shared packet buffer are
    /// confined to this serial queue.
    private let queue = DispatchQueue(label: "VmnetBridge")
    private var interface: interface_ref?
    private var hostSocket: Int32 = -1
    private var socketSource: DispatchSourceRead?
    private var packetBuffer: UnsafeMutableRawPointer?
    private var maxPacketSize = 0
    private var dhcpWatch: DHCPWatch?
    private var guestMAC: VZMACAddress?

    /// Starts a vmnet interface bridged onto the physical LAN and returns the
    /// VM's end of the socketpair for VZFileHandleNetworkDeviceAttachment.
    func start(stateDirectory: URL, cancellation: VMStartCancellation) throws -> Connection {
        try cancellation.check()
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw HAOSError("socketpair() failed: \(String(cString: strerror(errno)))")
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

        let macAddress: VZMACAddress
        let hostInterface: String
        do {
            hostInterface = try Self.sharedInterfaceName(cancellation: cancellation)
            macAddress = try startInterface(interfaceID: interfaceID(stateDirectory: stateDirectory),
                                            sharedInterface: hostInterface, cancellation: cancellation)
        } catch {
            close(vmSide)
            close(hostSide)
            throw error
        }

        queue.sync {
            hostSocket = hostSide
            packetBuffer = .allocate(byteCount: maxPacketSize, alignment: MemoryLayout<UInt>.alignment)
            guestMAC = macAddress

            vmnet_interface_set_event_callback(interface!, .VMNET_INTERFACE_PACKETS_AVAILABLE, queue) {
                [weak self] _, _ in self?.forwardToGuest()
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: hostSide, queue: queue)
            source.setEventHandler { [weak self] in self?.forwardToHost() }
            source.setCancelHandler { close(hostSide) }
            source.resume()
            socketSource = source
        }

        return Connection(fileHandle: FileHandle(fileDescriptor: vmSide, closeOnDealloc: true),
                          macAddress: macAddress,
                          hostInterface: Self.displayName(of: hostInterface))
    }

    /// Has `onOutcome` told, on the bridge's queue, when the guest's DHCP
    /// requests go unanswered and when they get answered again. Frames
    /// before this call aren't inspected; the guest hasn't booted yet when
    /// the bridge is started, so nothing is missed by calling it right after.
    func watchDHCP(onOutcome: @escaping (DHCPWatch.Outcome) -> Void) {
        queue.async { [self] in
            guard let guestMAC else { return }
            dhcpWatch = DHCPWatch(guestMAC: guestMAC, queue: queue, onChange: onOutcome)
        }
    }

    /// Detaches forwarding on its queue before stopping vmnet. A missing or
    /// rejected stop callback cannot hold up app termination indefinitely.
    func stop() {
        let interface: interface_ref? = queue.sync {
            let interface = self.interface
            self.interface = nil
            if let interface {
                vmnet_interface_set_event_callback(interface, .VMNET_INTERFACE_PACKETS_AVAILABLE, nil, nil)
            }
            socketSource?.cancel()
            socketSource = nil
            hostSocket = -1
            dhcpWatch?.cancel()
            dhcpWatch = nil
            guestMAC = nil
            packetBuffer?.deallocate()
            packetBuffer = nil
            return interface
        }
        guard let interface else { return }
        let done = DispatchSemaphore(value: 0)
        let status = vmnet_stop_interface(interface, queue) { result in
            if result != .VMNET_SUCCESS {
                log.error("Could not stop bridged interface: \(Self.describe(result), privacy: .public)")
            }
            done.signal()
        }
        guard status == .VMNET_SUCCESS else {
            log.error("Bridged interface stop was rejected: \(Self.describe(status), privacy: .public)")
            return
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            log.error("Timed out waiting for bridged interface shutdown")
        }
    }

    // MARK: - vmnet interface

    /// Lives on the start attempt's queue, including after the caller has timed out.
    /// The callback retains this attempt so a late success can still be stopped.
    private final class InterfaceStart {
        var interface: interface_ref?
        var abandoned = false
        var stopScheduled = false
        var result: Result<(VZMACAddress, Int), Error>?

        func abandon(on queue: DispatchQueue) {
            abandoned = true
            guard !stopScheduled, let interface else { return }
            stopScheduled = vmnet_stop_interface(interface, queue) { status in
                if status != .VMNET_SUCCESS {
                    log.error("Could not stop abandoned bridged interface: \(status.rawValue)")
                }
            } == .VMNET_SUCCESS
        }
    }

    private func startInterface(interfaceID: UUID, sharedInterface: String,
                                cancellation: VMStartCancellation) throws -> VZMACAddress {
        let desc = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, UInt64(operating_modes_t.VMNET_BRIDGED_MODE.rawValue))
        xpc_dictionary_set_string(desc, vmnet_shared_interface_name_key, sharedInterface)
        var uuid = interfaceID.uuid
        withUnsafeBytes(of: &uuid) {
            xpc_dictionary_set_uuid(desc, vmnet_interface_id_key,
                                    $0.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }

        let done = DispatchSemaphore(value: 0)
        let attempt = InterfaceStart()
        // A system authorization prompt can hold the start call itself. Its
        // queue must not prevent teardown of the packet-forwarding queue.
        let queue = DispatchQueue(label: "VmnetBridge.start")
        queue.async {
            attempt.interface = vmnet_start_interface(desc, queue) { status, params in
                if status == .VMNET_SUCCESS, let params,
                   let cString = xpc_dictionary_get_string(params, vmnet_mac_address_key),
                   let mac = VZMACAddress(string: String(cString: cString)),
                   xpc_dictionary_get_uint64(params, vmnet_max_packet_size_key) > 0 {
                    attempt.result = .success((mac, Int(xpc_dictionary_get_uint64(params, vmnet_max_packet_size_key))))
                } else {
                    attempt.result = .failure(HAOSError("vmnet failed to start bridged interface: \(Self.describe(status))"))
                }
                if attempt.abandoned { attempt.abandon(on: queue) }
                done.signal()
            }
            if attempt.interface == nil {
                attempt.result = .failure(HAOSError("vmnet_start_interface() rejected the configuration"))
                done.signal()
            }
        }
        // vmnet_start_interface has been known to never call back on some
        // OS/hardware combinations, which would hang the start indefinitely.
        // Time out and surface an error instead.
        let deadline = DispatchTime.now() + Self.interfaceStartTimeout
        do {
            while done.wait(timeout: .now() + 0.1) == .timedOut {
                try cancellation.check()
                if DispatchTime.now() >= deadline {
                    throw HAOSError("Bridged networking timed out bringing up the interface. Try a different network interface — a USB/Thunderbolt ethernet adapter, if you have one.")
                }
            }
            try cancellation.check()
            let (mac, packetSize, interface) = try queue.sync {
                guard let result = attempt.result, let interface = attempt.interface else {
                    throw HAOSError("Bridged networking did not return an interface.")
                }
                let (mac, packetSize) = try result.get()
                return (mac, packetSize, interface)
            }
            self.queue.sync {
                self.interface = interface
                self.maxPacketSize = packetSize
            }
            return mac
        } catch {
            queue.async { attempt.abandon(on: queue) }
            throw error
        }
    }

    /// How long to wait for `vmnet_start_interface` to call back before
    /// treating the start as hung.
    private static let interfaceStartTimeout: TimeInterval = 60

    /// vmnet → guest: drain everything vmnet has queued, one datagram per
    /// ethernet frame. Runs on `queue`.
    private func forwardToGuest() {
        guard let interface, let buffer = packetBuffer else { return }
        // Yield between batches so sustained traffic cannot starve teardown.
        for _ in 0..<64 {
            var iov = iovec(iov_base: buffer, iov_len: maxPacketSize)
            let frameSize = withUnsafeMutablePointer(to: &iov) { iovPointer -> Int in
                var packet = vmpktdesc(vm_pkt_size: maxPacketSize, vm_pkt_iov: iovPointer,
                                       vm_pkt_iovcnt: 1, vm_flags: 0)
                var count: Int32 = 1
                guard vmnet_read(interface, &packet, &count) == .VMNET_SUCCESS, count > 0 else { return 0 }
                return packet.vm_pkt_size
            }
            guard frameSize > 0 else { return }
            dhcpWatch?.sawFrameToGuest(buffer, length: frameSize)
            _ = send(hostSocket, buffer, frameSize, 0) // EAGAIN drops the frame
        }
        queue.async { [weak self] in self?.forwardToGuest() }
    }

    /// guest → vmnet: drain the socket. Runs on `queue`.
    private func forwardToHost() {
        guard let interface, let buffer = packetBuffer else { return }
        for _ in 0..<64 {
            let size = recv(hostSocket, buffer, maxPacketSize, 0)
            guard size > 0 else { return }
            dhcpWatch?.sawFrameFromGuest(buffer, length: size)
            var iov = iovec(iov_base: buffer, iov_len: size)
            withUnsafeMutablePointer(to: &iov) { iovPointer in
                var packet = vmpktdesc(vm_pkt_size: size, vm_pkt_iov: iovPointer,
                                       vm_pkt_iovcnt: 1, vm_flags: 0)
                var count: Int32 = 1
                _ = vmnet_write(interface, &packet, &count)
            }
        }
    }

    /// How long to wait for a bridgeable interface before giving up. The app
    /// autostarts at login, which after a reboot happens well before Wi-Fi has
    /// associated or an ethernet link has trained; failing immediately would
    /// mean the VM never starts on exactly the launch that matters most.
    /// The wait is event-driven, so its length costs nothing in time-to-ready —
    /// it only bounds how long a hopeless start hangs around before erroring.
    private static let interfaceWaitTimeout: TimeInterval = 60

    /// Backstop re-check interval. Configd drives the wait; this only covers
    /// a change vmnet sees that configd didn't post a key for.
    private static let interfaceRecheckInterval: TimeInterval = 5

    /// The physical interface to bridge onto, waiting up to
    /// `interfaceWaitTimeout` for one to appear. Returns as soon as a
    /// candidate is live, so a machine that is already online pays nothing and
    /// one whose Wi-Fi is still associating starts the moment it finishes.
    private static func sharedInterfaceName(cancellation: VMStartCancellation) throws -> String {
        let deadline = Date() + interfaceWaitTimeout
        // Created before the first check so a link coming up in between still
        // signals — the semaphore holds the wakeup rather than dropping it.
        let watcher = NetworkChangeWatcher()
        defer { watcher.stop() }
        while true {
            try cancellation.check()
            if let name = liveBridgeableInterface() { return name }
            guard Date() < deadline else {
                throw HAOSError("no physical interface with an active link available for bridged networking (waited \(Int(interfaceWaitTimeout))s for the network to come up)")
            }
            try watcher.waitForChange(until: min(deadline, Date() + interfaceRecheckInterval), cancellation: cancellation)
        }
    }

    /// Picks a physical interface to bridge onto, or nil if none is usable
    /// right now. Only interfaces whose link is actually up are considered —
    /// vmnet lists a built-in ethernet port even with no cable plugged in, and
    /// bridging onto it silently yields a dead network. Among live interfaces,
    /// wired is preferred over Wi-Fi; within a class, the default-route
    /// interface wins.
    private static func liveBridgeableInterface() -> String? {
        var bridgeable: [String] = []
        if let list = vmnet_copy_shared_interface_list() {
            for index in 0..<xpc_array_get_count(list) {
                if let name = xpc_array_get_string(list, index) {
                    bridgeable.append(String(cString: name))
                }
            }
        }
        let store = SCDynamicStoreCreate(nil, "VmnetBridge" as CFString, nil, nil)
        bridgeable = bridgeable.filter { linkIsActive($0, store: store) }
        var wifi = Set<String>()
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            if SCNetworkInterfaceGetInterfaceType(interface) == kSCNetworkInterfaceTypeIEEE80211,
               let bsdName = SCNetworkInterfaceGetBSDName(interface) {
                wifi.insert(bsdName as String)
            }
        }
        var primary: String?
        if let store,
           let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            primary = global["PrimaryInterface"] as? String
        }
        let wired = bridgeable.filter { !wifi.contains($0) }
        for candidates in [wired, bridgeable] where !candidates.isEmpty {
            if let primary, candidates.contains(primary) { return primary }
            return candidates[0]
        }
        return nil
    }

    /// Whether the interface's link is up, per configd's per-interface Link
    /// state. An interface with no state key (some virtual adapters) is
    /// assumed live rather than silently excluded.
    private static func linkIsActive(_ name: String, store: SCDynamicStore?) -> Bool {
        guard let store,
              let link = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(name)/Link" as CFString) as? [String: Any],
              let active = link["Active"] as? Bool else { return true }
        return active
    }

    /// "Wi-Fi (en0)": the name System Settings shows for the interface, with
    /// the BSD name for anyone comparing against `ifconfig`.
    private static func displayName(of bsdName: String) -> String {
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        where SCNetworkInterfaceGetBSDName(interface) as String? == bsdName {
            if let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                return "\(name) (\(bsdName))"
            }
        }
        return bsdName
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
        case .VMNET_INVALID_ACCESS: return "not permitted (check the virtualization entitlement)"
        case .VMNET_SHARING_SERVICE_BUSY: return "sharing service busy"
        default: return "status \(status.rawValue)"
        }
    }
}
