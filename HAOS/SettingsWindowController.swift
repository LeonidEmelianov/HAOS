import AppKit

/// Settings window for the VM's CPU count, memory size and the folder shared
/// with the guest. Selections are written to UserDefaults immediately (no OK
/// button, per macOS convention) and take effect the next time the VM starts.
final class SettingsWindowController: NSWindowController {
    private let cpuPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let memoryPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var sharedFolderCheckbox = NSButton(
        checkboxWithTitle: "Share a folder with Home Assistant",
        target: self,
        action: #selector(toggleSharedFolder))
    private let sharedFolderPath = NSTextField(labelWithString: "")
    private lazy var chooseFolderButton = NSButton(
        title: "Choose…", target: self, action: #selector(chooseSharedFolder))
    private let guestFolderPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sharedFolderNote = NSTextField(labelWithString: "")

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
        let sharingLabel = NSTextField(labelWithString: "Sharing:")
        let folderLabel = NSTextField(labelWithString: "Folder:")
        let guestFolderLabel = NSTextField(labelWithString: "Use as:")

        // A long path would otherwise stretch the window without limit.
        sharedFolderPath.lineBreakMode = .byTruncatingMiddle
        sharedFolderPath.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

        let folderRow = NSStackView(views: [sharedFolderPath, chooseFolderButton])
        folderRow.spacing = 8

        let note = NSTextField(labelWithString:
            "Changes take effect the next time Home Assistant starts.")
        for caption in [sharedFolderNote, note] {
            caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            caption.textColor = .secondaryLabelColor
        }
        // A label is single-line until told otherwise, and this one wraps and
        // changes length as the guest folder changes.
        sharedFolderNote.usesSingleLineMode = false
        sharedFolderNote.lineBreakMode = .byWordWrapping
        sharedFolderNote.maximumNumberOfLines = 0
        sharedFolderNote.preferredMaxLayoutWidth = 380
        sharedFolderNote.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let grid = NSGridView(views: [
            [cpuLabel, cpuPopUp],
            [memoryLabel, memoryPopUp],
            [sharingLabel, sharedFolderCheckbox],
            [folderLabel, folderRow],
            [guestFolderLabel, guestFolderPopUp],
        ])
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        // The notes are the widest elements; keeping them out of the grid lets
        // the label/control rows sit centered in the window instead of hugging
        // the left edge.
        let content = NSView()
        for view in [grid, sharedFolderNote, note] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            sharedFolderNote.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            sharedFolderNote.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            sharedFolderNote.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            note.topAnchor.constraint(equalTo: sharedFolderNote.bottomAnchor, constant: 10),
            note.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            note.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
    }

    /// Rebuilds the controls from current defaults and host limits, then
    /// fronts the window.
    func show() {
        populatePopUps()
        populateGuestFolderPopUp()
        updateSharedFolderControls()
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

    // MARK: - Shared folder

    /// Each popup item writes its value to VMSettings when selected, the same
    /// way the CPU and memory popups do.
    private func populateGuestFolderPopUp() {
        let menu = NSMenu()
        for folder in VMSettings.GuestFolder.allCases {
            menu.addItem(ClosureMenuItem(title: folder.title) { [weak self] in
                VMSettings.sharedFolderGuest = folder
                self?.updateSharedFolderControls()
            })
        }
        guestFolderPopUp.menu = menu
    }

    private func updateSharedFolderControls() {
        let enabled = VMSettings.sharedFolderEnabled
        let guestFolder = VMSettings.sharedFolderGuest
        sharedFolderCheckbox.state = enabled ? .on : .off
        if let url = VMSettings.sharedFolderURL {
            sharedFolderPath.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        } else {
            sharedFolderPath.stringValue = "No folder chosen"
        }
        sharedFolderPath.textColor = enabled ? .labelColor : .secondaryLabelColor
        chooseFolderButton.isEnabled = enabled
        guestFolderPopUp.isEnabled = enabled
        guestFolderPopUp.selectItem(withTitle: guestFolder.title)

        sharedFolderNote.stringValue = guestFolder.summary
            + " Whatever the guest already keeps there stays inside the VM, hidden, "
            + "until sharing is turned off."
        // The note's height changes with the folder, and the window was sized
        // to fit the one it opened with.
        if let content = window?.contentView {
            content.layoutSubtreeIfNeeded()
            window?.setContentSize(content.fittingSize)
        }
    }

    /// Turning sharing on with no folder yet goes straight to the open panel —
    /// there's nothing to share until one is picked, so a checkbox left on
    /// while the folder says "none" would be a lie. Cancelling puts it back.
    @objc private func toggleSharedFolder() {
        VMSettings.sharedFolderEnabled = sharedFolderCheckbox.state == .on
        updateSharedFolderControls()
        if VMSettings.sharedFolderEnabled, VMSettings.sharedFolderURL == nil {
            presentFolderPanel { chosen in
                guard !chosen else { return }
                VMSettings.sharedFolderEnabled = false
            }
        }
    }

    @objc private func chooseSharedFolder() {
        presentFolderPanel { _ in }
    }

    private func presentFolderPanel(completion: @escaping (_ chosen: Bool) -> Void) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder to share with Home Assistant."
        panel.directoryURL = VMSettings.sharedFolderURL
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                VMSettings.sharedFolderURL = url
                completion(true)
            } else {
                completion(false)
            }
            self?.updateSharedFolderControls()
        }
    }
}
