import AppKit
import ServiceManagement

/// Ties the app together: keeps the VM running, feeds its state to the menu
/// bar, and opens the windows the menu asks for. The app has no Dock icon or
/// main window; the console and settings windows open on demand.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let vmController = VMController()
    private let console = ConsoleWindowController()
    private var settingsWindowController: SettingsWindowController?

    private lazy var menuBar = MenuBarController(actions: MenuBarController.Actions(
        start: { [weak self] in self?.startVM() },
        stop: { [weak self] in
            self?.cancelStartRetry()
            self?.vmController.requestStop()
        },
        showConsole: { [weak self] in self?.showConsole() },
        openWebUI: { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.vmController.webUIURL)
        },
        showAbout: { AboutPanel.show() },
        openSettings: { [weak self] in self?.openSettings() }))

    /// Last state reported by the controller; drives the whole menu.
    private var vmState: VMState = .stopped(error: nil)

    /// Set once the app is quitting, so the guest shutting down can finish the
    /// termination the menu started.
    private var isTerminating = false

    /// Builds the status item and its menu, then starts the VM right away —
    /// the app's whole point is to keep Home Assistant running.
    func applicationDidFinishLaunching(_ notification: Notification) {
        registerLoginItem()

        vmController.onStateChange = { [weak self] state in self?.apply(state) }
        menuBar.update(for: vmState)
        startVM(userInitiated: false)
    }

    /// Reflects a VM state change in the menu, and finishes a quit that was
    /// waiting on the guest.
    private func apply(_ state: VMState) {
        vmState = state
        menuBar.update(for: state)
        if isTerminating, state.isStopped {
            isTerminating = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// Registers the app to start automatically at login (visible under
    /// System Settings → General → Login Items, where it can be disabled).
    /// Only the installed copy owns autostart — a Debug build run from
    /// DerivedData must not register its own path.
    private func registerLoginItem() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("Login item registration failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Starting the VM

    /// Number of automatic start attempts before giving up. The network case
    /// is already handled inside the attempt — `VmnetBridge` waits on configd
    /// for a live interface — so these retries are the backstop for everything
    /// else (a transient vmnet failure, a network still absent a minute in).
    private static let startRetryLimit = 6

    /// Delay between automatic start attempts.
    private static let startRetryDelay: TimeInterval = 5

    /// The scheduled retry, kept so a start or shutdown the user asks for in
    /// the meantime can cancel it — a retry must never resurrect a VM the
    /// user just shut down.
    private var pendingStartRetry: DispatchWorkItem?

    /// Starts the VM (downloading the disk image first, on first launch).
    /// The menu updates via `onStateChange`.
    ///
    /// A start the user asked for reports failure in an alert. The automatic
    /// start at launch doesn't: after a reboot the app runs before the network
    /// is up (and `VmnetBridge` only waits so long for it), so a first attempt
    /// can fail for a reason that fixes itself moments later. Those attempts
    /// retry in the background and leave the reason in the menu's status line
    /// rather than throwing a modal at a user who may not even be at the Mac.
    private func startVM(userInitiated: Bool = true, attempt: Int = 1) {
        guard vmState.canStart else { return }
        if userInitiated { cancelStartRetry() }
        vmController.start { [weak self] result in
            guard let self, case .failure(let error) = result else { return }
            guard userInitiated else {
                self.scheduleStartRetry(after: attempt, error: error)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Failed to start Home Assistant VM"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    /// Queues another automatic start attempt, or gives up and leaves the
    /// failure visible in the menu.
    private func scheduleStartRetry(after attempt: Int, error: Error) {
        guard attempt < Self.startRetryLimit else {
            NSLog("Giving up starting the VM after %d attempts: %@",
                  attempt, error.localizedDescription)
            return
        }
        NSLog("VM start attempt %d failed (%@); retrying in %.0fs",
              attempt, error.localizedDescription, Self.startRetryDelay)
        let retry = DispatchWorkItem { [weak self] in
            self?.pendingStartRetry = nil
            self?.startVM(userInitiated: false, attempt: attempt + 1)
        }
        pendingStartRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startRetryDelay, execute: retry)
    }

    private func cancelStartRetry() {
        pendingStartRetry?.cancel()
        pendingStartRetry = nil
    }

    // MARK: - Windows

    private func showConsole() {
        guard let vm = vmController.virtualMachine else { return }
        console.show(vm)
    }

    /// Opens (creating on first use) the settings window.
    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.show()
    }

    // MARK: - Termination

    /// How long the guest gets to shut down cleanly before it's killed.
    private static let shutdownGracePeriod: TimeInterval = 30

    /// Asks the guest to shut down cleanly before quitting; force stops after
    /// a grace period. Either way the reply comes from `apply(_:)`, once the
    /// VM reports itself stopped.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard vmController.isRunning else { return .terminateNow }

        cancelStartRetry()
        isTerminating = true
        vmController.requestStop()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shutdownGracePeriod) { [weak self] in
            guard let self, self.isTerminating else { return }
            guard self.vmController.isRunning else {
                // Neither running nor stopped: the guest is wedged partway
                // through its shutdown, and the user asked to quit.
                self.isTerminating = false
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            self.vmController.forceStop()
        }
        return .terminateLater
    }
}
