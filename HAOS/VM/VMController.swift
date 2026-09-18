import Foundation
@preconcurrency import Virtualization
import os

/// Owns the Home Assistant VM: assembles the machine from its features, drives
/// the start/stop lifecycle, and reports each transition through
/// `onStateChange`.
///
/// The controller knows about CPUs, memory and firmware. Everything else the
/// guest has — its disk, its place on the network, the shared folder, the
/// console — belongs to a `VMFeature`.
final class VMController: NSObject, VZVirtualMachineDelegate {
    /// Called on every state transition, always on the main queue.
    var onStateChange: ((VMState) -> Void)?

    /// The live VM while one exists; also the handle a
    /// `VZVirtualMachineView` needs to show the guest's display.
    private(set) var virtualMachine: VZVirtualMachine?

    /// URL where the Home Assistant web UI is reachable. The router assigns
    /// the bridged guest's address; mDNS finds it.
    let webUIURL = URL(string: "http://homeassistant.local:8123")!

    /// The machine's capabilities, in the order their host-side preparation
    /// runs: the disk image has to be downloaded before the shared folder can
    /// edit the guest's boot files inside it.
    private let features: [VMFeature] = [
        DiskImageVMFeature(),
        SharedFolderVMFeature(),
        PowerButtonVMFeature(),
        NoSMEVMFeature(),
        NetworkVMFeature(),
        DisplayVMFeature(),
    ]

    /// Held while the VM runs, so the Mac doesn't idle-sleep out from under
    /// the guest.
    private let sleepAssertion = SleepAssertion(reason: "Home Assistant VM running")

    /// Tells the menu when Home Assistant itself is up, which the guest
    /// running says nothing about.
    private lazy var webUIProbe = WebUIProbe(webUIURL: webUIURL)

    /// Preparation and configuration run here rather than on a global queue:
    /// a first launch downloads several hundred MB on this thread, and that
    /// shouldn't tie up a thread the rest of the system is sharing.
    private let startQueue = DispatchQueue(label: "HAOS.VMController.start")

    /// True from the moment a start is asked for until the guest is running
    /// or the attempt has failed, so a second request can't run the features
    /// twice over the same disk image.
    private var isStarting = false

    /// The two things the running state is made of, kept so that either can
    /// change without losing the other: the web UI probe moves Home
    /// Assistant along while a feature raises or clears a problem.
    private var homeAssistantProgress: HomeAssistantProgress = .starting
    private var guestProblem: String?

    /// True from a shutdown request until the guest is gone: the VM still
    /// reports itself running, but the status line says "Stopping…" and a
    /// late problem report mustn't take that back.
    private var isStopping = false

    /// Persistent VM state (EFI variable store, machine identifier) lives in
    /// ~/Library/Application Support/HAOS/
    private let stateDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("HAOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Where the Home Assistant OS disk image lives on the host.
    private let diskImageURL = DiskImageVMFeature.imageURL

    /// True while the guest is up (not while starting, stopping or downloading).
    var isRunning: Bool {
        virtualMachine?.state == .running
    }

    private var featureContext: VMFeatureContext {
        VMFeatureContext(
            stateDirectory: stateDirectory,
            diskImageURL: diskImageURL,
            reportProgress: { [weak self] status in
                self?.report(.provisioning(progress: status))
            },
            reportProblem: { [weak self] problem in
                DispatchQueue.main.async {
                    // A problem from a run that has since ended is stale.
                    guard let self, self.isRunning, !self.isStopping else { return }
                    log.notice("Guest problem: \(problem ?? "cleared", privacy: .public)")
                    self.guestProblem = problem
                    self.reportRunning()
                }
            })
    }

    private func reportRunning() {
        report(.running(homeAssistant: homeAssistantProgress, problem: guestProblem))
    }

    /// Delivers a state change on the main queue. Most transitions already
    /// happen there; a download reporting its progress does not.
    private func report(_ state: VMState) {
        if Thread.isMainThread {
            onStateChange?(state)
        } else {
            DispatchQueue.main.async { self.onStateChange?(state) }
        }
    }

    // MARK: - Configuration (per Apple "Running GUI Linux in a VM on a Mac")

    /// The bare machine, with each feature's devices added to it.
    private func makeConfiguration(in context: VMFeatureContext) throws
        -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = VMSettings.cpuCount
        configuration.memorySize = VMSettings.memorySize

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = machineIdentifier()
        configuration.platform = platform

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = try efiVariableStore()
        configuration.bootLoader = bootLoader

        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        for feature in features {
            try feature.configure(configuration, in: context)
        }

        try configuration.validate()
        return configuration
    }

    private func efiVariableStore() throws -> VZEFIVariableStore {
        let url = stateDirectory.appendingPathComponent("NVRAM")
        if FileManager.default.fileExists(atPath: url.path) {
            return VZEFIVariableStore(url: url)
        }
        return try VZEFIVariableStore(creatingVariableStoreAt: url)
    }

    private func machineIdentifier() -> VZGenericMachineIdentifier {
        let url = stateDirectory.appendingPathComponent("MachineIdentifier")
        if let data = try? Data(contentsOf: url),
           let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            return identifier
        }
        let identifier = VZGenericMachineIdentifier()
        try? identifier.dataRepresentation.write(to: url)
        return identifier
    }

    // MARK: - Lifecycle

    /// Boots the VM, downloading the disk image first if this is the first
    /// launch. `completion` is called once the guest is running or the attempt
    /// has failed; progress along the way arrives via `onStateChange`.
    func start(completion: @escaping (Result<VZVirtualMachine, Error>) -> Void) {
        guard !isStarting, virtualMachine == nil else { return }
        isStarting = true
        sleepAssertion.begin()
        report(.starting)

        // Off the main thread: the first launch downloads and unpacks the disk
        // image, and starting the vmnet interface blocks until macOS resolves
        // the one-time bridged-network authorization. The app has to stay
        // responsive (menu bar icon, system prompt) through both.
        startQueue.async { [weak self] in
            guard let self else { return }
            do {
                // No image yet means this start downloads one, and the guest
                // will spend its first boot installing Home Assistant.
                let isFirstBoot = !FileManager.default.fileExists(atPath: self.diskImageURL.path)
                let context = self.featureContext
                for feature in self.features {
                    try feature.prepare(in: context)
                }
                let configuration = try self.makeConfiguration(in: context)
                DispatchQueue.main.async {
                    self.boot(configuration, isFirstBoot: isFirstBoot, completion: completion)
                }
            } catch {
                DispatchQueue.main.async { self.failStart(error, completion: completion) }
            }
        }
    }

    private func boot(_ configuration: VZVirtualMachineConfiguration, isFirstBoot: Bool,
                      completion: @escaping (Result<VZVirtualMachine, Error>) -> Void) {
        // Progress from a first-launch download has been sitting in the status
        // line; the machine is past that now.
        report(.starting)

        let vm = VZVirtualMachine(configuration: configuration)
        vm.delegate = self
        virtualMachine = vm
        vm.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.isStarting = false
                self.homeAssistantProgress = isFirstBoot ? .installing : .starting
                self.guestProblem = nil
                self.isStopping = false
                self.reportRunning()
                self.watchForHomeAssistant()
                completion(.success(vm))
            case .failure(let error):
                self.failStart(error, completion: completion)
            }
        }
    }

    /// Keeps the status line honest about Home Assistant once the guest is
    /// up. What answers on the web UI port says which phase the guest is in
    /// better than the first-boot guess: a guest quit halfway through its
    /// install is still installing on the boot after.
    private func watchForHomeAssistant() {
        webUIProbe.start { [weak self] sighting in
            guard let self, self.isRunning, !self.isStopping else { return }
            switch sighting {
            case .nothing: return
            case .placeholder: self.homeAssistantProgress = .installing
            case .homeAssistant: self.homeAssistantProgress = .ready
            }
            self.reportRunning()
        }
    }

    private func failStart(_ error: Error,
                           completion: @escaping (Result<VZVirtualMachine, Error>) -> Void) {
        isStarting = false
        virtualMachine = nil
        releaseResources()
        report(.failed(error: error.localizedDescription))
        completion(.failure(error))
    }

    /// Hands back everything a run holds: the features' host resources (the
    /// vmnet interface, above all) and the sleep assertion. Every stop path —
    /// guest shutdown, error stop, force stop, failed start — ends here.
    private func releaseResources() {
        webUIProbe.stop()
        for feature in features {
            feature.tearDown()
        }
        sleepAssertion.end()
    }

    /// Graceful shutdown: presses the guest's power button, which
    /// `PowerButtonVMFeature` has taught Home Assistant OS to honor.
    /// `onStateChange` reports `.stopped` once the guest is off; if the
    /// request can't even be delivered, the caller's grace period still ends
    /// in a force stop, so the failure is only logged.
    func requestStop() {
        guard let vm = virtualMachine, vm.state == .running else { return }
        isStopping = true
        report(.stopping)
        do {
            try vm.requestStop()
        } catch {
            log.error("Could not ask the guest to shut down: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Kills the VM without giving the guest a chance to shut down. Used as
    /// the last resort when a graceful shutdown times out. The stop is
    /// reported through `onStateChange` like any other.
    func forceStop() {
        guard let vm = virtualMachine, vm.state == .running else { return }
        vm.stop { [weak self] _ in self?.finishStop(error: nil) }
    }

    private func finishStop(error: String?) {
        virtualMachine = nil
        releaseResources()
        report(.stopped(error: error))
    }

    // MARK: - VZVirtualMachineDelegate

    /// The guest powered itself off (e.g. shutdown from the HA UI).
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        finishStop(error: nil)
    }

    /// The VM died with an error (crash, device failure).
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        finishStop(error: error.localizedDescription)
    }
}
