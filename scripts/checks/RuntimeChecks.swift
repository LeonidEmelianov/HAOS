import Foundation
import Virtualization

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private func until(_ message: String, _ condition: () -> Bool) {
    let deadline = Date() + 5
    while !condition() {
        require(Date() < deadline, "Timed out: \(message)")
        RunLoop.current.run(until: Date() + 0.005)
    }
}

private final class PausedFeature: VMFeature {
    let prepared = DispatchSemaphore(value: 0)
    let continuePreparation = DispatchSemaphore(value: 0)
    let cleaning = DispatchSemaphore(value: 0)
    let continueCleanup = DispatchSemaphore(value: 0)
    let failPreparation: Bool
    var configured = false
    var cleanupCount = 0

    init(failPreparation: Bool = false) { self.failPreparation = failPreparation }

    func prepare(in context: VMFeatureContext) throws {
        prepared.signal()
        continuePreparation.wait()
        if failPreparation { throw HAOSError("Expected preparation failure") }
    }

    func configure(_ configuration: VZVirtualMachineConfiguration, in context: VMFeatureContext) {
        configured = true
        fatalError("Canceled or failed preparation must never configure a VM")
    }

    func tearDown() {
        require(!Thread.isMainThread, "Cleanup blocked the main thread")
        cleanupCount += 1
        cleaning.signal()
        continueCleanup.wait()
    }
}

@main
private enum RuntimeChecks {
    static func main() throws {
        let directory = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("haos-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try settingsSnapshot(in: directory)
        lifecycle(in: directory, failPreparation: false)
        lifecycle(in: directory, failPreparation: true)
        try consoleBackpressure(in: directory)
        print("Passed: settings snapshot, canceled/failed startup cleanup, console backpressure")
    }

    private static func settingsSnapshot(in directory: URL) throws {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        defaults.setVolatileDomain([
            "VMCPUCount": 2, "VMMemorySize": UInt64(2) << 30,
            "VMDiskSize": UInt64(48) << 30, "NetworkMode": "shared",
            "SharedFolderEnabled": true, "SharedFolderPath": directory.path,
            "SharedFolderGuestPath": "/mnt/data/supervisor/media", "SharedFolderReadOnly": true,
        ], forName: UserDefaults.argumentDomain)
        let settings = VMSettingsSnapshot()
        defaults.setVolatileDomain([
            "VMCPUCount": 4, "VMMemorySize": UInt64(4) << 30,
            "VMDiskSize": UInt64(96) << 30, "NetworkMode": "bridged",
            "SharedFolderEnabled": false, "SharedFolderReadOnly": false,
        ], forName: UserDefaults.argumentDomain)
        require(settings.cpuCount == 2 && settings.memorySize == UInt64(2) << 30, "Machine settings drifted")
        require(settings.diskSize == UInt64(48) << 30 && settings.networkMode == .shared, "Feature settings drifted")
        require(settings.sharedFolder.kernelParameter ==
                "systemd.mount-extra=haos-shared:/mnt/data/supervisor/media:virtiofs:ro,nofail", "Boot mount drifted")
        let context = VMFeatureContext(stateDirectory: directory,
                                      diskImageURL: directory.appendingPathComponent("unused.img"),
                                      settings: settings, cancellation: VMStartCancellation(),
                                      reportProgress: { _ in }, reportProblem: { _ in })
        let configuration = VZVirtualMachineConfiguration()
        try SharedFolderVMFeature().configure(configuration, in: context)
        let device = configuration.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration
        let share = device?.share as? VZSingleDirectoryShare
        require(share?.directory.url.path == directory.path && share?.directory.isReadOnly == true,
                "Host share did not use the same settings as the boot mount")
    }

    private static func lifecycle(in directory: URL, failPreparation: Bool) {
        let feature = PausedFeature(failPreparation: failPreparation)
        let controller = VMController(features: [feature], stateDirectory: directory,
                                      diskImageURL: directory.appendingPathComponent("unused.img"))
        var lastState: VMState = .stopped(error: nil)
        var startCompletions = 0
        var stopCompletions = 0
        controller.onStateChange = { lastState = $0 }
        controller.start { result in
            startCompletions += 1
            guard case .failure(let error) = result else { fatalError("Unexpected boot") }
            require((error is CancellationError) == !failPreparation, "Wrong startup result")
        }
        until("preparation entered") { feature.prepared.wait(timeout: .now()) == .success }
        if !failPreparation {
            controller.requestStop { result in
                require((try? result.get()) != nil, "Cancellation failed")
                stopCompletions += 1
            }
            controller.requestStop { _ in stopCompletions += 1 }
        }
        require(controller.isBusy && !lastState.canStart, "Start became available during preparation")
        feature.continuePreparation.signal()
        until("cleanup entered") { feature.cleaning.wait(timeout: .now()) == .success }
        var mainQueueResponsive = false
        DispatchQueue.main.async { mainQueueResponsive = true }
        until("main queue stayed responsive") { mainQueueResponsive }
        require(controller.isBusy && !lastState.canStart, "Start became available before cleanup finished")
        require(startCompletions == 0 && stopCompletions == 0, "Completion preceded cleanup")
        feature.continueCleanup.signal()
        until("cleanup finished") { !controller.isBusy }
        require(startCompletions == 1, "Start completion was lost or repeated")
        require(stopCompletions == (failPreparation ? 0 : 2), "Stop completions were lost or repeated")
        require(!feature.configured && feature.cleanupCount == 1, "Incorrect feature lifecycle")
        require(lastState.canStart, "Controller did not become idle")
    }

    private static func consoleBackpressure(in directory: URL) throws {
        let socketURL = directory.appendingPathComponent("console.sock")
        let relay = ConsoleRelay(socketURL: socketURL)
        relay.start()
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        require(client >= 0, "Could not create console client")
        defer { close(client) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketURL.path.utf8CString)
        require(path.count <= MemoryLayout.size(ofValue: address.sun_path), "Test socket path too long")
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        require(connected == 0, "Could not connect to console")
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
        let expected = (0..<(48 * 1024)).map { UInt8($0 % 251) }
        var queued = 0
        until("queued console input") {
            let count = expected.withUnsafeBytes {
                write(client, $0.baseAddress! + queued, $0.count - queued)
            }
            if count > 0 { queued += count }
            return queued == expected.count
        }
        let attachment = relay.attachment as! VZFileHandleSerialPortAttachment
        let guestFD = attachment.fileHandleForReading!.fileDescriptor
        _ = fcntl(guestFD, F_SETFL, fcntl(guestFD, F_GETFL) | O_NONBLOCK)
        var received = [UInt8]()
        until("buffered console delivery") {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(guestFD, &buffer, buffer.count)
            if count > 0 { received.append(contentsOf: buffer.prefix(count)) }
            return received.count == expected.count
        }
        require(received == expected, "Console backpressure lost or reordered input")

        let payload = [UInt8](repeating: 120, count: 4096)
        var sent = 0
        let deadline = Date() + 2
        // No reader drains the guest's input pipe, just as with a stalled guest.
        while Date() < deadline && sent < 256 * 1024 {
            let count = payload.withUnsafeBytes { write(client, $0.baseAddress!, $0.count) }
            if count > 0 { sent += count }
            else if errno != EAGAIN && errno != EINTR { break }
            RunLoop.current.run(until: Date() + 0.001)
        }
        require(sent >= 64 * 1024, "Did not exercise input backpressure")

        // Once the guest reads again, everything the client sent arrives: the
        // client was paused, not dropped, and its input wasn't discarded.
        var drained = 0
        until("console input resumed after backpressure") {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = read(guestFD, &buffer, buffer.count)
            if count > 0 { drained += count }
            return drained == sent
        }

        // Stall it again for the teardown check.
        sent = 0
        let refill = Date() + 2
        while Date() < refill && sent < 256 * 1024 {
            let count = payload.withUnsafeBytes { write(client, $0.baseAddress!, $0.count) }
            if count > 0 { sent += count }
            else if errno != EAGAIN && errno != EINTR { break }
            RunLoop.current.run(until: Date() + 0.001)
        }
        require(sent >= 64 * 1024, "Did not stall the console again")
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            relay.stop()
            relay.stop()
            stopped.signal()
        }
        until("console teardown with a stalled guest") { stopped.wait(timeout: .now()) == .success }
        require(!FileManager.default.fileExists(atPath: socketURL.path), "Console socket survived teardown")
    }
}
