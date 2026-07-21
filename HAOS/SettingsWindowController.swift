import AppKit

/// Settings window for the VM's CPU count and memory size. Selections are
/// written to UserDefaults immediately (no OK button, per macOS convention)
/// and take effect the next time the VM starts.
final class SettingsWindowController: NSWindowController {
    private let cpuPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let memoryPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    convenience init() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Home Assistant Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)

        let cpuLabel = NSTextField(labelWithString: "CPU cores:")
        let memoryLabel = NSTextField(labelWithString: "Memory:")
        let note = NSTextField(labelWithString: "Changes take effect the next time Home Assistant starts.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [cpuLabel, cpuPopUp],
            [memoryLabel, memoryPopUp],
        ])
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        // The note is the widest element; keeping it out of the grid lets the
        // label/popup rows sit centered in the window instead of hugging the
        // left edge.
        let content = NSView()
        for view in [grid, note] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            note.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            note.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            note.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
    }

    /// Rebuilds the popups from current defaults and host limits, then fronts
    /// the window.
    func show() {
        populatePopUps()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Each popup item writes its value to VMSettings when selected
    /// (a pop-up button dispatches the selected item's own action).
    private func populatePopUps() {
        let cpuMenu = NSMenu()
        for count in VMSettings.allowedCPUCounts {
            cpuMenu.addItem(ClosureMenuItem(title: "\(count)") { VMSettings.cpuCount = count })
        }
        cpuPopUp.menu = cpuMenu
        cpuPopUp.selectItem(withTitle: "\(VMSettings.cpuCount)")

        // Common sizes within what the host allows, plus the current value
        // if the user somehow ended up in between.
        let currentGiB = Int(VMSettings.memorySize >> 30)
        var choices = [2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128]
            .filter { VMSettings.allowedMemorySizes.contains(UInt64($0) << 30) }
        if !choices.contains(currentGiB) {
            choices.append(currentGiB)
            choices.sort()
        }
        let memoryMenu = NSMenu()
        for gib in choices {
            memoryMenu.addItem(ClosureMenuItem(title: "\(gib) GB") { VMSettings.memorySize = UInt64(gib) << 30 })
        }
        memoryPopUp.menu = memoryMenu
        memoryPopUp.selectItem(withTitle: "\(currentGiB) GB")
    }
}
