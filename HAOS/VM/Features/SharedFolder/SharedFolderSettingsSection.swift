import AppKit

/// The shared-folder section of the Settings window: the on/off checkbox, the
/// folder picker, the popup choosing where the guest mounts it, and the
/// caption explaining what that means. Lives with the rest of the feature, so
/// the window only has to place the rows it hands back.
///
/// Selections are written to `SharedFolderSettings` immediately (no OK button,
/// per macOS convention) and take effect the next time the VM starts.
final class SharedFolderSettingsSection {
    /// Width of the wrapping caption, and with it the settings window's
    /// widest row.
    private static let noteWidth: CGFloat = 340

    private lazy var checkbox = NSButton(
        checkboxWithTitle: "Share a folder with Home Assistant",
        target: self,
        action: #selector(toggleSharing))
    private let pathLabel = NSTextField(labelWithString: "")
    private lazy var chooseButton = NSButton(
        title: "Choose…", target: self, action: #selector(chooseFolder))
    private let guestFolderPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let note = SettingsLabel.wrappingCaption("", width: noteWidth)
    private let folderLabel = NSTextField(labelWithString: "Folder:")
    private let guestFolderLabel = NSTextField(labelWithString: "Use as:")

    /// The section's rows, ready to be placed in the Settings window.
    lazy var rows: [SettingsRow] = {
        // A long path would otherwise stretch the window without limit.
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true

        note.widthAnchor.constraint(equalToConstant: Self.noteWidth).isActive = true
        // The caption's text changes with the guest folder. Reserving the
        // tallest variant's height keeps the window from resizing under the
        // pointer every time the popup changes.
        note.heightAnchor.constraint(equalToConstant: Self.tallestNoteHeight).isActive = true

        let folderRow = NSStackView(views: [pathLabel, chooseButton])
        folderRow.spacing = 8

        return [
            .header("Shared folder"),
            .control(checkbox),
            .field(label: folderLabel, control: folderRow),
            .field(label: guestFolderLabel, control: guestFolderPopUp),
            .caption(note),
        ]
    }()

    /// Rebuilds the controls from the stored settings. Called each time the
    /// window is shown.
    func refresh() {
        populateGuestFolderPopUp()
        updateControls()
    }

    /// Each popup item writes its value when selected (a pop-up button
    /// dispatches the selected item's own action).
    private func populateGuestFolderPopUp() {
        let menu = NSMenu()
        for folder in SharedFolderSettings.GuestFolder.allCases {
            menu.addItem(ClosureMenuItem(title: folder.title) { [weak self] in
                SharedFolderSettings.guestFolder = folder
                self?.updateControls()
            })
        }
        guestFolderPopUp.menu = menu
    }

    private func updateControls() {
        let enabled = SharedFolderSettings.isEnabled
        let guestFolder = SharedFolderSettings.guestFolder
        checkbox.state = enabled ? .on : .off
        if let url = SharedFolderSettings.folderURL {
            pathLabel.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        } else {
            pathLabel.stringValue = "No folder chosen"
        }
        chooseButton.isEnabled = enabled
        guestFolderPopUp.isEnabled = enabled
        guestFolderPopUp.selectItem(withTitle: guestFolder.title)
        note.stringValue = Self.noteText(for: guestFolder)

        // Dimming the whole sub-section, labels included, is how macOS shows
        // controls that the checkbox above them has switched off.
        for label in [folderLabel, guestFolderLabel] {
            label.textColor = enabled ? .labelColor : .disabledControlTextColor
        }
        pathLabel.textColor = enabled ? .labelColor : .disabledControlTextColor
        note.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
    }

    /// Turning sharing on with no folder yet goes straight to the open panel —
    /// there's nothing to share until one is picked, so a checkbox left on
    /// while the folder says "none" would be a lie. Cancelling puts it back.
    @objc private func toggleSharing() {
        SharedFolderSettings.isEnabled = checkbox.state == .on
        updateControls()
        if SharedFolderSettings.isEnabled, SharedFolderSettings.folderURL == nil {
            presentFolderPanel { chosen in
                guard !chosen else { return }
                SharedFolderSettings.isEnabled = false
            }
        }
    }

    @objc private func chooseFolder() {
        presentFolderPanel { _ in }
    }

    private func presentFolderPanel(completion: @escaping (_ chosen: Bool) -> Void) {
        // The panel hangs off whichever window the section was placed in.
        guard let window = checkbox.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder to share with Home Assistant."
        panel.directoryURL = SharedFolderSettings.folderURL
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                SharedFolderSettings.folderURL = url
                completion(true)
            } else {
                completion(false)
            }
            self?.updateControls()
        }
    }

    /// Height of the tallest caption, so the window can be sized once for
    /// whichever guest folder the user picks. Measured with a label configured
    /// like the real one rather than with `boundingRect`, which wraps text on
    /// its own terms and comes up a line short.
    private static var tallestNoteHeight: CGFloat {
        let ruler = SettingsLabel.wrappingCaption("", width: noteWidth)
        let heights = SharedFolderSettings.GuestFolder.allCases.map { folder -> CGFloat in
            ruler.stringValue = noteText(for: folder)
            return ruler.sizeThatFits(
                NSSize(width: noteWidth, height: .greatestFiniteMagnitude)).height
        }
        return ceil(heights.max() ?? 0)
    }

    private static func noteText(for folder: SharedFolderSettings.GuestFolder) -> String {
        folder.summary
            + " Whatever the guest already keeps there stays inside the VM, hidden, "
            + "until sharing is turned off."
    }
}
