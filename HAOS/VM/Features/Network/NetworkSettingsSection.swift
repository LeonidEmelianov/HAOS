import AppKit

/// The network section of the Settings window: the popup choosing between
/// bridged and shared networking, and the caption saying what the choice
/// costs. Lives with the rest of the feature, so the window only has to
/// place the rows it hands back.
///
/// The selection is written to `NetworkSettings` immediately (no OK button,
/// per macOS convention) and takes effect the next time the VM starts.
final class NetworkSettingsSection {
    private let modePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let note = SettingsLabel.reservedCaption(
        fitting: NetworkSettings.Mode.allCases.map(\.summary))

    /// The section's rows, ready to be placed in the Settings window.
    lazy var rows: [SettingsRow] = [
        .header("Network"),
        .field(label: NSTextField(labelWithString: "Connection:"), control: modePopUp),
        .caption(note),
    ]

    /// Rebuilds the controls from the stored setting. Called each time the
    /// window is shown.
    func refresh() {
        // Each popup item writes its value when selected (a pop-up button
        // dispatches the selected item's own action).
        let menu = NSMenu()
        for mode in NetworkSettings.Mode.allCases {
            menu.addItem(ClosureMenuItem(title: mode.title) { [weak self] in
                NetworkSettings.mode = mode
                self?.updateControls()
            })
        }
        modePopUp.menu = menu
        updateControls()
    }

    private func updateControls() {
        let mode = NetworkSettings.mode
        modePopUp.selectItem(withTitle: mode.title)
        note.stringValue = mode.summary
    }
}
