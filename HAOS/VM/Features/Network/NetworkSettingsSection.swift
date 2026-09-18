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
    private let note = SettingsLabel.wrappingCaption("")

    /// The section's rows, ready to be placed in the Settings window.
    lazy var rows: [SettingsRow] = {
        note.widthAnchor.constraint(equalToConstant: SettingsLabel.noteWidth).isActive = true
        // The caption's text changes with the mode. Reserving the tallest
        // variant's height keeps the window from resizing under the pointer.
        note.heightAnchor.constraint(equalToConstant: Self.tallestNoteHeight).isActive = true

        return [
            .header("Network"),
            .field(label: NSTextField(labelWithString: "Connection:"), control: modePopUp),
            .caption(note),
        ]
    }()

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

    /// Height of the tallest caption, so the window can be sized once for
    /// whichever mode the user picks. Measured with a label configured like
    /// the real one rather than with `boundingRect`, which wraps text on its
    /// own terms and comes up a line short.
    private static var tallestNoteHeight: CGFloat {
        let ruler = SettingsLabel.wrappingCaption("")
        let heights = NetworkSettings.Mode.allCases.map { mode -> CGFloat in
            ruler.stringValue = mode.summary
            return ruler.sizeThatFits(
                NSSize(width: SettingsLabel.noteWidth, height: .greatestFiniteMagnitude)).height
        }
        return ceil(heights.max() ?? 0)
    }
}
