import Foundation
@preconcurrency import Virtualization

/// VM configuration. CPU count and memory size are user-adjustable in the
/// Settings window (persisted in UserDefaults); the rest is hardcoded.
/// Changes take effect the next time the VM starts.
enum VMSettings {
    /// Where the Home Assistant OS disk image lives on the host.
    static let diskImagePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/HAOS/HAOS.img").path

    private static let cpuCountKey = "VMCPUCount"
    private static let memorySizeKey = "VMMemorySize"

    /// CPU cores given to the guest when the user hasn't chosen otherwise.
    static let defaultCPUCount = 2

    /// Memory given to the guest when the user hasn't chosen otherwise.
    static let defaultMemorySize: UInt64 = 4 * 1024 * 1024 * 1024 // 4 GiB

    /// HAOS needs headroom for the Supervisor and add-on containers; below
    /// 2 GiB the guest OOMs during onboarding.
    static let minimumMemorySize: UInt64 = 2 * 1024 * 1024 * 1024 // 2 GiB

    /// Host limits from Virtualization.framework, queried at read time so a
    /// value saved on one machine can't produce an invalid configuration on
    /// another.
    static var allowedCPUCounts: ClosedRange<Int> {
        VZVirtualMachineConfiguration.minimumAllowedCPUCount
            ... VZVirtualMachineConfiguration.maximumAllowedCPUCount
    }

    /// Memory sizes the host accepts, floored at `minimumMemorySize`.
    static var allowedMemorySizes: ClosedRange<UInt64> {
        max(minimumMemorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
            ... VZVirtualMachineConfiguration.maximumAllowedMemorySize
    }

    /// The guest's CPU count, clamped to what the host allows.
    static var cpuCount: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: cpuCountKey)
            let value = stored > 0 ? stored : defaultCPUCount
            return min(max(value, allowedCPUCounts.lowerBound), allowedCPUCounts.upperBound)
        }
        set { UserDefaults.standard.set(newValue, forKey: cpuCountKey) }
    }

    /// The guest's memory size in bytes, clamped to what the host allows.
    static var memorySize: UInt64 {
        get {
            let stored = (UserDefaults.standard.object(forKey: memorySizeKey) as? NSNumber)?
                .uint64Value ?? defaultMemorySize
            return min(max(stored, allowedMemorySizes.lowerBound), allowedMemorySizes.upperBound)
        }
        set { UserDefaults.standard.set(NSNumber(value: newValue), forKey: memorySizeKey) }
    }

    /// Virtual disk size. HAOS ships a ~6 GiB image and expands its data
    /// partition to fill the disk on boot; without growing the image first,
    /// the data partition is too small for the Supervisor containers and the
    /// HA CLI never comes up. The file stays sparse on APFS, so this costs
    /// only what the guest actually writes.
    static let diskSize: UInt64 = 64 * 1024 * 1024 * 1024 // 64 GiB

    /// Guest display resolution, in pixels. The console window opens at these
    /// dimensions in *points*, so on a Retina host each framebuffer pixel is
    /// drawn 2x and the Linux console's fixed 8x16 font stays legible. Raising
    /// this shrinks the text: the guest keeps the same glyph size and just
    /// fits more of them on screen.
    static let displayWidth = 1280
    static let displayHeight = 800
}

/// Owns the Home Assistant VM: builds the Virtualization.framework
/// configuration, downloads the disk image on first launch, and drives the
/// start/stop lifecycle, reporting each transition through `onStateChange`.
final class VMController: NSObject, VZVirtualMachineDelegate {
    /// Called on every state transition. Not guaranteed to arrive on the
    /// main queue — hop before touching UI.
    var onStateChange: ((VMState) -> Void)?

    /// The live VM while one exists; also the handle a
    /// `VZVirtualMachineView` needs to show the guest's display.
    private(set) var virtualMachine: VZVirtualMachine?

    /// URL where the Home Assistant web UI is reachable. The router assigns
    /// the bridged guest's address; mDNS finds it.
    let webUIURL = URL(string: "http://homeassistant.local:8123")!

    /// Bridged network backend; a fresh instance is created for every VM start.
    private var vmnetBridge: VmnetBridge?

    /// Non-nil while the disk image is being downloaded on first launch.
    private var imageDownloader: ImageDownloader?

    /// Held while the VM runs. A host that idle-sleeps freezes the guest;
    /// LAN peers then expire their ARP entries and reset every persistent
    /// connection to Home Assistant, so each wake costs seconds of
    /// reconnection lag (or drops events entirely). Also exempts the app
    /// from App Nap, which would throttle the in-process VM.
    private var sleepPreventionToken: NSObjectProtocol?

    /// Persistent VM state (EFI variable store, machine identifier) lives in
    /// ~/Library/Application Support/HAOS/
    private let stateDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("HAOS", isDirectory: true)
        // Builds before 0.1.0 kept this state under HAOSMenuBar/. Move it
        // across rather than starting fresh: a new directory would mean a new
        // machine identifier, an empty EFI store and a new vmnet interface
        // UUID, so the guest would come back with a different MAC and lose
        // its DHCP lease.
        let legacy = base.appendingPathComponent("HAOSMenuBar", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// True while the guest is up (not while starting, stopping or downloading).
    var isRunning: Bool {
        virtualMachine?.state == .running
    }

    // MARK: - Configuration (per Apple "Running GUI Linux in a VM on a Mac")

    private func createEFIVariableStore() throws -> VZEFIVariableStore {
        let url = stateDirectory.appendingPathComponent("NVRAM")
        if FileManager.default.fileExists(atPath: url.path) {
            return VZEFIVariableStore(url: url)
        }
        return try VZEFIVariableStore(creatingVariableStoreAt: url)
    }

    private func getOrCreateMachineIdentifier() -> VZGenericMachineIdentifier {
        let url = stateDirectory.appendingPathComponent("MachineIdentifier")
        if let data = try? Data(contentsOf: url),
           let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            return identifier
        }
        let identifier = VZGenericMachineIdentifier()
        try? identifier.dataRepresentation.write(to: url)
        return identifier
    }

    /// Extends the raw image file to `size` (the equivalent of
    /// `qemu-img resize` for raw images). Never shrinks: a user-grown image
    /// larger than the default is left alone.
    private func growDiskImage(at url: URL, to size: UInt64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        guard try handle.seekToEnd() < size else { return }
        try handle.truncate(atOffset: size)
    }

    private func createConfiguration() throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = VMSettings.cpuCount
        configuration.memorySize = VMSettings.memorySize

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = getOrCreateMachineIdentifier()
        configuration.platform = platform

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = try createEFIVariableStore()
        configuration.bootLoader = bootLoader

        let diskURL = URL(fileURLWithPath: VMSettings.diskImagePath)
        guard FileManager.default.fileExists(atPath: diskURL.path) else {
            throw NSError(domain: "HAOS", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Disk image not found at \(diskURL.path)"
            ])
        }
        try growDiskImage(at: diskURL, to: VMSettings.diskSize)
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        let bridge = VmnetBridge()
        self.vmnetBridge = bridge
        let fileHandle = try bridge.start(stateDirectory: stateDirectory)
        networkDevice.macAddress = bridge.macAddress!
        networkDevice.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: fileHandle)
        configuration.networkDevices = [networkDevice]

        let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
        graphicsDevice.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: VMSettings.displayWidth,
                                                 heightInPixels: VMSettings.displayHeight)
        ]
        configuration.graphicsDevices = [graphicsDevice]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        try configuration.validate()
        return configuration
    }

    // MARK: - Lifecycle

    private func beginSleepPrevention() {
        guard sleepPreventionToken == nil else { return }
        sleepPreventionToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Home Assistant VM running")
    }

    private func endSleepPrevention() {
        guard let token = sleepPreventionToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        sleepPreventionToken = nil
    }

    /// Tears down the network backend. Every stop path (guest shutdown,
    /// error stop, force stop, failed start) ends here, so the sleep
    /// assertion is released here too.
    private func stopNetwork() {
        vmnetBridge?.stop()
        vmnetBridge = nil
        endSleepPrevention()
    }

    /// Boots the VM, downloading the disk image first if this is the first
    /// launch. `completion` is called once the guest is running or the
    /// attempt has failed; progress along the way arrives via `onStateChange`.
    func start(completion: @escaping (Result<VZVirtualMachine, Error>) -> Void) {
        guard imageDownloader == nil else { return } // download already underway

        beginSleepPrevention()

        // First launch: no disk image yet — fetch the latest HAOS release.
        // (createConfiguration grows it to VMSettings.diskSize before boot.)
        guard FileManager.default.fileExists(atPath: VMSettings.diskImagePath) else {
            let downloader = ImageDownloader(destination: URL(fileURLWithPath: VMSettings.diskImagePath))
            imageDownloader = downloader
            downloader.downloadLatestImage(
                progress: { [weak self] status in
                    DispatchQueue.main.async { self?.onStateChange?(.provisioning(progress: status)) }
                },
                completion: { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.imageDownloader = nil
                        switch result {
                        case .success:
                            self.launch(completion: completion)
                        case .failure(let error):
                            self.stopNetwork()
                            self.onStateChange?(.failed)
                            completion(.failure(error))
                        }
                    }
                })
            return
        }

        launch(completion: completion)
    }

    private func launch(completion: @escaping (Result<VZVirtualMachine, Error>) -> Void) {
        onStateChange?(.starting)
        // Configuration must stay off the main thread: starting the vmnet
        // interface blocks until macOS resolves the one-time bridged-network
        // authorization, and the app must stay responsive (menu bar icon,
        // system prompt) while that happens.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let configuration = try self.createConfiguration()
                DispatchQueue.main.async {
                    let vm = VZVirtualMachine(configuration: configuration)
                    vm.delegate = self
                    self.virtualMachine = vm
                    vm.start { result in
                        switch result {
                        case .success:
                            self.onStateChange?(.running)
                            completion(.success(vm))
                        case .failure(let error):
                            self.virtualMachine = nil
                            self.stopNetwork()
                            self.onStateChange?(.failed)
                            completion(.failure(error))
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.virtualMachine = nil
                    self.stopNetwork()
                    self.onStateChange?(.failed)
                    completion(.failure(error))
                }
            }
        }
    }

    /// Graceful shutdown: sends an ACPI power-button event so HAOS shuts
    /// down cleanly. `onStateChange` reports `.stopped` once the guest is off.
    func requestStop() {
        guard let vm = virtualMachine, vm.state == .running else { return }
        onStateChange?(.stopping)
        try? vm.requestStop()
    }

    /// Kills the VM without giving the guest a chance to shut down. Used as
    /// the last resort when a graceful shutdown times out.
    func forceStop(completion: @escaping () -> Void) {
        guard let vm = virtualMachine, vm.state == .running else {
            completion()
            return
        }
        vm.stop { [weak self] _ in
            self?.virtualMachine = nil
            self?.stopNetwork()
            self?.onStateChange?(.stopped(error: nil))
            completion()
        }
    }

    // MARK: - VZVirtualMachineDelegate

    /// The guest powered itself off (e.g. shutdown from the HA UI).
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        self.virtualMachine = nil
        stopNetwork()
        onStateChange?(.stopped(error: nil))
    }

    /// The VM died with an error (crash, device failure).
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        self.virtualMachine = nil
        stopNetwork()
        onStateChange?(.stopped(error: error.localizedDescription))
    }
}
