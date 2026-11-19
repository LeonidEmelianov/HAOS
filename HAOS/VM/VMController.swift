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
    private let features: [VMFeature]

    /// Held while the VM runs, so the Mac doesn't idle-sleep out from under
    /// the guest.
    private let sleepAssertion = SleepAssertion(reason: "Home Assistant VM running")

    /// Tells the menu when Home Assistant itself is up, which the guest
    /// running says nothing about.
    private lazy var webUIProbe = WebUIProbe(webUIURL: webUIURL)

    /// Tells the menu when the Supervisor is what Home Assistant is waiting
    /// for, through the Observer it serves next to the web UI.
    private let supervisorProbe = SupervisorProbe(
        observerURL: URL(string: "http://homeassistant.local:4357")!)

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
    private var supervisorActivity: String?
    private var guestProblem: String?

    /// True from a shutdown request until the guest is gone: the VM still
    /// reports itself running, but the status line says "Stopping…" and a
    /// late problem report mustn't take that back.
    private var isStopping = false
    private var isCleaningUp = false
    private var cancellation: VMStartCancellation?
    private var runID = UUID()
    private var shutdownTimeout: DispatchWorkItem?
    private var stopCompletions: [(Result<Void, Error>) -> Void] = []

    /// Includes preparation and cleanup, when the disk must still be left alone.
    var isBusy: Bool { isStarting || virtualMachine != nil || isCleaningUp }

    /// A restored guest with several add-ons needed 25 seconds; leave headroom.
    private static let shutdownGracePeriod: TimeInterval = 60

    /// Persistent VM state (EFI variable store, machine identifier) lives in
    /// ~/Library/Application Support/HAOS/
    private let stateDirectory: URL
    private let diskImageURL: URL

    init(features: [VMFeature]? = nil, stateDirectory: URL? = nil,
         diskImageURL: URL = DiskImageVMFeature.imageURL) {
        self.features = features ?? [
            DiskImageVMFeature(),
            SharedFolderVMFeature(),
            PowerButtonVMFeature(),
            NoSMEVMFeature(),
            SerialConsoleVMFeature(),
            NetworkVMFeature(),
            DisplayVMFeature(),
        ]
        self.stateDirectory = stateDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HAOS", isDirectory: true)
        self.diskImageURL = diskImageURL
        super.init()
        try? FileManager.default.createDirectory(at: self.stateDirectory, withIntermediateDirectories: true)
    }

    /// Whether the framework still considers the guest running, including a graceful shutdown.
    var isRunning: Bool {
        virtualMachine?.state == .running
    }

    private func featureContext(settings: VMSettingsSnapshot,
                                cancellation: VMStartCancellation) -> VMFeatureContext {
        let runID = self.runID
        return VMFeatureContext(
            stateDirectory: stateDirectory,
            diskImageURL: diskImageURL,
            settings: settings,
            cancellation: cancellation,
            reportProgress: { [weak self] status in
                DispatchQueue.main.async {
                    guard let self, self.runID == runID, self.isStarting,
                          !self.isStopping else { return }
                    self.report(.provisioning(progress: status))
                }
            },
            reportProblem: { [weak self] problem in
                DispatchQueue.main.async {
                    // A problem from a run that has since ended is stale.
                    guard let self, self.runID == runID, self.isRunning, !self.isStopping else { return }
                    log.notice("Guest problem: \(problem ?? "cleared", privacy: .public)")
                    self.guestProblem = problem
                    self.reportRunning()
                }
            })
    }

    private func reportRunning() {
        let progress = supervisorActivity.map { .waitingForSupervisor($0) } ?? homeAssistantProgress
        report(.running(homeAssistant: progress, problem: guestProblem))
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
        configuration.cpuCount = context.settings.cpuCount
        configuration.memorySize = context.settings.memorySize

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = machineIdentifier()
        configuration.platform = platform

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = try efiVariableStore()
        configuration.bootLoader = bootLoader

        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        for feature in features {
            try context.cancellation.check()
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
        guard !isBusy else {
            completion(.failure(HAOSError("Home Assistant is already starting, running or stopping.")))
            return
        }
        isStarting = true
        isStopping = false
        runID = UUID()
        let cancellation = VMStartCancellation()
        self.cancellation = cancellation
        let context = featureContext(settings: VMSettingsSnapshot(), cancellation: cancellation)
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
                for feature in self.features {
                    try cancellation.check()
                    try feature.prepare(in: context)
                }
                try cancellation.check()
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
        guard cancellation?.isCancelled == false else {
            failStart(CancellationError(), completion: completion)
            return
        }
        // Progress from a first-launch download has been sitting in the status
        // line; the machine is past that now.
        report(.starting)

        let vm = VZVirtualMachine(configuration: configuration)
        vm.delegate = self
        virtualMachine = vm
        vm.start { [weak self] result in
            guard let self, self.virtualMachine === vm else { return }
            switch result {
            case .success:
                self.isStarting = false
                if self.isStopping {
                    completion(.failure(CancellationError()))
                    self.shutDown(vm)
                    return
                }
                self.homeAssistantProgress = isFirstBoot ? .installing : .starting
                self.supervisorActivity = nil
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
            case .homeAssistant:
                self.homeAssistantProgress = .ready
                self.supervisorActivity = nil
                self.supervisorProbe.stop()
            }
            self.reportRunning()
        }
        supervisorProbe.start { [weak self] activity in
            guard let self, self.isRunning, !self.isStopping else { return }
            self.supervisorActivity = activity
            self.reportRunning()
        }
    }

    private func failStart(_ error: Error,
                           completion: @escaping (Result<VZVirtualMachine, Error>) -> Void) {
        isStarting = false
        virtualMachine = nil
        // Decided now: a stop asked for during cleanup didn't cause this
        // failure, and mustn't hide it.
        let cancelled = isStopping || error is CancellationError
        releaseResources {
            self.isStopping = false
            self.report(cancelled ? .stopped(error: nil) : .failed(error: error.localizedDescription))
            completion(.failure(cancelled ? CancellationError() : error))
            self.completeStop(.success(()))
        }
    }

    /// Preparation and teardown share a queue, so cancellation never releases
    /// resources while a feature is still using them. The UI stays responsive.
    private func releaseResources(completion: @escaping () -> Void) {
        isCleaningUp = true
        shutdownTimeout?.cancel()
        shutdownTimeout = nil
        webUIProbe.stop()
        supervisorProbe.stop()
        startQueue.async {
            for feature in self.features.reversed() {
                feature.tearDown()
            }
            DispatchQueue.main.async {
                self.sleepAssertion.end()
                self.cancellation = nil
                self.isCleaningUp = false
                completion()
            }
        }
    }

    /// Menu shutdown and application termination use the same cancellation,
    /// grace period and cleanup. Completion means the disk is no longer in use.
    func requestStop(completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        guard isBusy else {
            completion(.success(()))
            return
        }
        stopCompletions.append(completion)
        guard !isStopping else { return }
        isStopping = true
        cancellation?.cancel()
        report(.stopping)
        // Preparation finishes its current disk edit; an in-flight VZ start
        // must finish before the framework accepts a stop request.
        guard !isStarting, !isCleaningUp, let vm = virtualMachine else { return }
        shutDown(vm)
    }

    private func shutDown(_ vm: VZVirtualMachine) {
        let timeout = DispatchWorkItem { [weak self, weak vm] in
            guard let self, let vm, self.virtualMachine === vm, self.isStopping else { return }
            self.forceStop(vm)
        }
        shutdownTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shutdownGracePeriod, execute: timeout)
        do {
            try vm.requestStop()
        } catch {
            log.error("Could not ask the guest to shut down: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func forceStop(_ vm: VZVirtualMachine) {
        if vm.state == .stopped {
            finishStop(error: nil)
            return
        }
        guard vm.canStop else {
            stopFailed(HAOSError("Home Assistant could not be stopped in its current state."))
            return
        }
        vm.stop { [weak self, weak vm] error in
            guard let self, let vm, self.virtualMachine === vm else { return }
            if let error {
                self.stopFailed(error)
            } else {
                self.finishStop(error: nil)
            }
        }
    }

    private func stopFailed(_ error: Error) {
        shutdownTimeout?.cancel()
        shutdownTimeout = nil
        isStopping = false
        guestProblem = "shutdown failed: \(error.localizedDescription); try Shut Down again"
        reportRunning()
        completeStop(.failure(error))
    }

    private func completeStop(_ result: Result<Void, Error>) {
        let completions = stopCompletions
        stopCompletions.removeAll()
        for completion in completions { completion(result) }
    }

    private func finishStop(error: String?) {
        guard !isCleaningUp else { return }
        virtualMachine = nil
        isStarting = false
        isStopping = true
        report(.stopping)
        releaseResources {
            self.isStopping = false
            self.report(.stopped(error: error))
            self.completeStop(.success(()))
        }
    }

    // MARK: - VZVirtualMachineDelegate

    /// The guest powered itself off (e.g. shutdown from the HA UI).
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        guard self.virtualMachine === virtualMachine else { return }
        finishStop(error: nil)
    }

    /// The VM died with an error (crash, device failure).
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        guard self.virtualMachine === virtualMachine else { return }
        finishStop(error: error.localizedDescription)
    }
}
