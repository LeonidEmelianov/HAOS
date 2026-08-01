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
    private static let sharedFolderEnabledKey = "SharedFolderEnabled"
    private static let sharedFolderPathKey = "SharedFolderPath"
    private static let sharedFolderGuestKey = "SharedFolderGuestPath"

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

    // MARK: - Shared folder

    /// virtiofs tag the share is published under, and the name the guest
    /// mounts it by.
    static let sharedFolderTag = "haos-shared"

    /// Which of the Supervisor's directories the share is mounted over inside
    /// the guest. A fixed set, not a free path: the value is spliced into the
    /// guest's kernel command line, and mounting over the wrong directory (the
    /// Home Assistant config, say) would hide the running configuration.
    enum GuestFolder: String, CaseIterable {
        case backup = "/mnt/data/supervisor/backup"
        case media = "/mnt/data/supervisor/media"
        case share = "/mnt/data/supervisor/share"

        /// Name for the Settings popup.
        var title: String {
            switch self {
            case .backup: return "Backups"
            case .media: return "Media"
            case .share: return "Share"
            }
        }

        /// What the folder is good for, for the caption under the popup.
        var summary: String {
            switch self {
            case .backup: return "Home Assistant writes its backups here."
            case .media: return "The folder shows up in Home Assistant's media browser."
            case .share: return "The folder shows up as /share, which add-ons read and write."
            }
        }
    }

    /// Identifies our kernel parameter in the guest's command line, whatever
    /// tag or directory it currently names — `haos-` is our own namespace, so
    /// a share left over from an older version is cleaned up too.
    static let sharedFolderParameterPrefix = "systemd.mount-extra=haos-"

    /// Kernel parameter that has the guest's systemd mount the share at boot,
    /// early enough that Docker and the Supervisor see it. `nofail` keeps a
    /// guest whose share has gone away — sharing turned off, an image moved to
    /// another Mac — from stalling its boot on a mount it can't make.
    static var sharedFolderKernelParameter: String {
        "systemd.mount-extra=\(sharedFolderTag):\(sharedFolderGuest.rawValue):virtiofs:rw,nofail"
    }

    /// Whether a folder on the Mac is shared with the guest. Off by default:
    /// turning it on hides whatever the guest already keeps in the directory
    /// the share is mounted over.
    static var sharedFolderEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: sharedFolderEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: sharedFolderEnabledKey) }
    }

    /// The shared folder's location on the Mac, or nil until the user picks
    /// one. There's no default: which folder to expose to the guest — and
    /// where in the Finder it belongs — is the user's call, not ours.
    static var sharedFolderURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: sharedFolderPathKey),
                  !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: sharedFolderPathKey) }
    }

    /// The folder to hand the guest: nil when sharing is off or no folder has
    /// been picked. Both the virtiofs device and the guest's mount come from
    /// this, so they can't disagree.
    static var activeSharedFolder: URL? {
        sharedFolderEnabled ? sharedFolderURL : nil
    }

    /// The directory the share is mounted over in the guest. Anything stored
    /// that isn't one of the known directories falls back to the default.
    static var sharedFolderGuest: GuestFolder {
        get {
            guard let stored = UserDefaults.standard.string(forKey: sharedFolderGuestKey),
                  let folder = GuestFolder(rawValue: stored) else { return .backup }
            return folder
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sharedFolderGuestKey) }
    }

    /// Virtual disk size. HAOS ships a ~6 GiB image and expands its data
    /// partition to fill the disk on boot; without growing the image first,
    /// the data partition is too small for the Supervisor containers and the
    /// HA CLI never comes up. The file stays sparse on APFS, so this costs
    /// only what the guest actually writes.
    static let diskSize: UInt64 = 48 * 1024 * 1024 * 1024 // 48 GiB

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
        updateSharedFolderMount()
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

        if let share = try sharedFolderDevice() {
            configuration.directorySharingDevices = [share]
        }

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

    /// The virtiofs device carrying the shared folder, or nil when there's
    /// nothing to share. The folder is recreated if the one the user picked
    /// has since been moved or deleted — an empty share beats a VM that
    /// won't start.
    private func sharedFolderDevice() throws -> VZVirtioFileSystemDeviceConfiguration? {
        guard let url = VMSettings.activeSharedFolder else { return nil }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let device = VZVirtioFileSystemDeviceConfiguration(tag: VMSettings.sharedFolderTag)
        device.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: url, readOnly: false))
        return device
    }

    /// Puts the guest's kernel command line in sync with the shared-folder
    /// setting. Offering the virtiofs device isn't enough — nothing in Home
    /// Assistant OS mounts it on its own, and its read-only root filesystem
    /// leaves the kernel command line as the only durable place to say so.
    ///
    /// A failure here is logged rather than raised: not mounting the share is
    /// a poor reason to leave Home Assistant down. The edit is attempted again
    /// on the next start.
    private func updateSharedFolderMount() {
        do {
            try GuestBootConfig.setKernelParameter(
                VMSettings.activeSharedFolder == nil ? nil : VMSettings.sharedFolderKernelParameter,
                replacingPrefix: VMSettings.sharedFolderParameterPrefix,
                imagePath: VMSettings.diskImagePath)
        } catch {
            NSLog("Could not update the guest's shared-folder mount: %@",
                  error.localizedDescription)
        }
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
                            self.onStateChange?(.failed(error: error.localizedDescription))
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
                            self.onStateChange?(.failed(error: error.localizedDescription))
                            completion(.failure(error))
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.virtualMachine = nil
                    self.stopNetwork()
                    self.onStateChange?(.failed(error: error.localizedDescription))
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
