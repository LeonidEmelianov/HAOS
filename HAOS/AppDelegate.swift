import AppKit
import ServiceManagement
import Virtualization

/// Menu bar UI for the Home Assistant VM: a status item whose menu starts,
/// stops and inspects the VM managed by `VMController`. The app has no Dock
/// icon or main window; the console and settings windows open on demand.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let vmController = VMController()
    private var displayWindow: NSWindow?
    private var settingsWindowController: SettingsWindowController?

    /// Last state reported by the controller; drives the whole menu.
    private var vmState: VMState = .stopped(error: nil)

    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    // Menu items are stored so updateMenuState() can show and hide them as
    // the VM moves through its lifecycle.
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var startItem = ClosureMenuItem(title: "Start Home Assistant") { [weak self] in
        self?.startVM()
    }
    private lazy var stopItem = ClosureMenuItem(title: "Shut Down") { [weak self] in
        self?.cancelStartRetry()
        self?.vmController.requestStop()
    }
    private lazy var showDisplayItem = ClosureMenuItem(title: "Show Console") { [weak self] in
        self?.showDisplay()
    }
    private lazy var openWebUIItem = ClosureMenuItem(title: "Open Web UI") { [weak self] in
        guard let self else { return }
        NSWorkspace.shared.open(self.vmController.webUIURL)
    }

    /// Builds the status item and its menu, then starts the VM right away —
    /// the app's whole point is to keep Home Assistant running.
    func applicationDidFinishLaunching(_ notification: Notification) {
        registerLoginItem()

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())
        menu.addItem(showDisplayItem)
        menu.addItem(openWebUIItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "About HAOS") { [weak self] in
            self?.showAbout()
        })
        menu.addItem(ClosureMenuItem(title: "Settings…", keyEquivalent: ",") { [weak self] in
            self?.openSettings()
        })
        menu.addItem(ClosureMenuItem(title: "Quit", keyEquivalent: "q") {
            NSApp.terminate(nil)
        })
        statusItem.menu = menu

        vmController.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.apply(state) }
        }

        apply(.stopped(error: nil))
        startVM(userInitiated: false)
    }

    /// Reflects a VM state change in the menu: status line, icon and which
    /// items are visible.
    private func apply(_ state: VMState) {
        vmState = state
        statusLine.title = state.menuTitle
        updateStatusIcon(for: state)
        updateMenuState()
    }

    /// Menu bar icon mirrors the VM lifecycle: filled house while running,
    /// power symbol while shutting down, dimmed for transitional/off states.
    private func updateStatusIcon(for state: VMState) {
        guard let button = statusItem.button else { return }
        let symbol: String
        let dimmed: Bool
        switch state {
        case .running:
            (symbol, dimmed) = ("house.fill", false)
        case .starting:
            (symbol, dimmed) = ("house.fill", true)
        case .stopping:
            (symbol, dimmed) = ("power", true)
        case .provisioning:
            (symbol, dimmed) = ("arrow.down.circle", true)
        case .stopped, .failed:
            (symbol, dimmed) = ("house", true)
        }
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Home Assistant: \(state.menuTitle)"
        )
        button.appearsDisabled = dimmed
        button.toolTip = "Home Assistant — \(state.menuTitle)"
    }

    /// Shows Start only while the VM is idle — not during the first-launch
    /// image download/unpack, boot or shutdown — and the running-VM items
    /// only while the guest is up.
    private func updateMenuState() {
        let running = vmState.isRunning
        startItem.isHidden = !vmState.canStart
        stopItem.isHidden = !running
        showDisplayItem.isHidden = !running
        openWebUIItem.isHidden = !running
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

    // MARK: - Menu actions

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
            DispatchQueue.main.async {
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
    }

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

    /// Opens (creating on first use) the window showing the guest's display.
    private func showDisplay() {
        guard let vm = vmController.virtualMachine else { return }

        if displayWindow == nil {
            let vmView = VZVirtualMachineView()
            vmView.capturesSystemKeys = false

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0,
                                    width: VMSettings.displayWidth,
                                    height: VMSettings.displayHeight),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "Home Assistant OS Console"
            // The guest's framebuffer is a fixed size; holding the window to
            // its aspect ratio makes resizing scale the console text instead
            // of letterboxing it.
            window.contentAspectRatio = NSSize(width: VMSettings.displayWidth,
                                               height: VMSettings.displayHeight)
            window.contentView = vmView
            window.isReleasedWhenClosed = false
            window.center()
            displayWindow = window
        }

        (displayWindow?.contentView as? VZVirtualMachineView)?.virtualMachine = vm
        displayWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shows the standard about panel — it renders the app icon, name and
    /// version from the bundle, so only the credits blurb is ours. An
    /// accessory app has to activate itself first or the panel opens behind
    /// whatever the user was in.
    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.aboutCredits])
    }

    /// Credits shown in the about panel: what the app does, plus a link to the
    /// upstream image the VM boots.
    private static let aboutCredits: NSAttributedString = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString(
            string: "Runs Home Assistant OS in a virtual machine on your Mac, bridged onto your local network.\n\n",
            attributes: body)
        credits.append(NSAttributedString(
            string: "Home Assistant OS releases",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .paragraphStyle: paragraph,
                .link: URL(string: "https://github.com/home-assistant/operating-system/releases")!,
            ]))
        return credits
    }()

    /// Opens (creating on first use) the settings window.
    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.show()
    }

    // MARK: - Termination

    /// Asks the guest to shut down cleanly before quitting; force stops after
    /// a grace period.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard vmController.isRunning else { return .terminateNow }

        vmController.requestStop()
        vmController.onStateChange = { state in
            if state.isStopped {
                DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
        // Force stop if the guest hasn't shut down within 30 seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.vmController.isRunning else { return }
            self.vmController.forceStop {
                DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
        return .terminateLater
    }
}
