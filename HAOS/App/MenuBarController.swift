import AppKit

/// The status item and its menu: a status line, the start/stop items and the
/// ways into the guest. It holds no VM logic of its own — the actions it's
/// built with do the work, and `update(for:)` decides what a given VM state
/// should look like.
final class MenuBarController {
    /// What the menu items do. Supplied by `AppDelegate`, which owns the VM.
    struct Actions {
        let start: () -> Void
        let stop: () -> Void
        let showConsole: () -> Void
        let openWebUI: () -> Void
        let showAbout: () -> Void
        let openSettings: () -> Void
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    // Kept so update(for:) can show and hide them as the VM moves through its
    // lifecycle.
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let startItem: ClosureMenuItem
    private let stopItem: ClosureMenuItem
    private let showConsoleItem: ClosureMenuItem
    private let openWebUIItem: ClosureMenuItem

    init(actions: Actions) {
        startItem = ClosureMenuItem(title: "Start Home Assistant", handler: actions.start)
        stopItem = ClosureMenuItem(title: "Shut Down", handler: actions.stop)
        showConsoleItem = ClosureMenuItem(title: "Show Console", handler: actions.showConsole)
        openWebUIItem = ClosureMenuItem(title: "Open Web UI", handler: actions.openWebUI)

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())
        menu.addItem(showConsoleItem)
        menu.addItem(openWebUIItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "About HAOS", handler: actions.showAbout))
        menu.addItem(ClosureMenuItem(title: "Settings…", keyEquivalent: ",",
                                     handler: actions.openSettings))
        menu.addItem(ClosureMenuItem(title: "Quit", keyEquivalent: "q") {
            NSApp.terminate(nil)
        })
        statusItem.menu = menu
    }

    /// Reflects a VM state in the menu: status line, icon, and which items are
    /// visible.
    func update(for state: VMState) {
        statusLine.title = state.menuTitle
        updateIcon(for: state)

        // Start shows only while the VM is idle — not during the first-launch
        // image download/unpack, boot or shutdown — and the running-VM items
        // only while the guest is up.
        startItem.isHidden = !state.canStart
        stopItem.isHidden = !state.isRunning
        showConsoleItem.isHidden = !state.isRunning
        openWebUIItem.isHidden = !state.isRunning
    }

    /// The icon mirrors the VM lifecycle: filled house while running, power
    /// symbol while shutting down, dimmed for transitional and off states.
    private func updateIcon(for state: VMState) {
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
            accessibilityDescription: "Home Assistant: \(state.menuTitle)")
        button.appearsDisabled = dimmed
        button.toolTip = "Home Assistant — \(state.menuTitle)"
    }
}
