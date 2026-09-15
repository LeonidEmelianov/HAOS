import AppKit

/// The disk section of the Settings window: a popup of virtual disk sizes, a
/// Resize button, and the caption saying what the disk is now and what it
/// will be. Lives with the rest of the feature, so the window only has to
/// place the rows it hands back.
///
/// Unlike the other settings, the size isn't written the moment the popup
/// changes: growing the disk can't be undone, so it waits for the button. The
/// image is grown right away when the VM is stopped, otherwise at its next
/// start.
final class DiskImageSettingsSection {
    /// Whether the disk image is free to be grown now — no VM is using it,
    /// and no download is writing it.
    private let vmIsIdle: () -> Bool

    private let sizePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var resizeButton = NSButton(
        title: "Resize", target: self, action: #selector(resize))
    private let note = SettingsLabel.wrappingCaption("")

    /// The size picked in the popup, applied when the button is pressed.
    private var chosenSize = DiskImageSettings.defaultSize

    init(vmIsIdle: @escaping () -> Bool) {
        self.vmIsIdle = vmIsIdle
    }

    /// The section's rows, ready to be placed in the Settings window.
    lazy var rows: [SettingsRow] = {
        note.widthAnchor.constraint(equalToConstant: SettingsLabel.noteWidth).isActive = true
        // The caption's text changes with the disk. Reserving the tallest
        // variant's height keeps the window from resizing under the pointer.
        note.heightAnchor.constraint(equalToConstant: Self.tallestNoteHeight).isActive = true

        let sizeRow = NSStackView(views: [sizePopUp, resizeButton])
        sizeRow.spacing = 8

        return [
            .header("Disk"),
            .field(label: NSTextField(labelWithString: "Disk size:"), control: sizeRow),
            .caption(note),
        ]
    }()

    /// Rebuilds the controls from the stored setting and the image on disk.
    /// Called each time the window is shown.
    func refresh() {
        chosenSize = effectiveSize
        populatePopUp()
        updateControls()
    }

    private var imageURL: URL { DiskImageVMFeature.imageURL }

    /// The size the disk has, or will have once Home Assistant next starts:
    /// the chosen size, unless the image is already bigger than that.
    private var effectiveSize: UInt64 {
        max(DiskImageSettings.size, DiskImageVMFeature.currentSize(of: imageURL) ?? 0)
    }

    /// The listed sizes, plus the disk's own size when it's in between (an
    /// image grown by hand, say), so the popup can always show what the disk
    /// is. Sizes the image can't take are left in the menu but disabled: it
    /// says why a size is off limits better than its absence would.
    private func populatePopUp() {
        let current = DiskImageVMFeature.currentSize(of: imageURL)
        let maximum = DiskImageVMFeature.maximumSize(for: imageURL)
        let effective = effectiveSize
        var choices = DiskImageSettings.choicesGiB.map { UInt64($0) * DiskImageSettings.gibibyte }
        if !choices.contains(where: {
            DiskImageSettings.title(for: $0) == DiskImageSettings.title(for: effective)
        }) {
            choices.append(effective)
            choices.sort()
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        for size in choices {
            let item = ClosureMenuItem(title: DiskImageSettings.title(for: size)) { [weak self] in
                self?.chosenSize = size
                self?.updateControls()
            }
            let tooSmall = size < (current ?? 0)
            let tooBig = maximum.map { size > $0 } ?? false
            // What the disk already is stays pickable whatever the limits
            // say: choosing it just means leaving things as they are.
            item.isEnabled = size == effective || !(tooSmall || tooBig)
            menu.addItem(item)
        }
        sizePopUp.menu = menu
    }

    private func updateControls() {
        sizePopUp.selectItem(withTitle: DiskImageSettings.title(for: chosenSize))
        resizeButton.isEnabled = chosenSize != effectiveSize
        note.stringValue = Self.noteText(
            current: DiskImageVMFeature.currentSize(of: imageURL),
            target: DiskImageSettings.size)
    }

    /// Records the chosen size and grows the image to it if nothing is using
    /// the image; otherwise the growth waits for the next start, which the
    /// caption says. Nothing here can shrink the disk — the popup only offers
    /// sizes at or above the image's own.
    @objc private func resize() {
        DiskImageSettings.size = chosenSize
        if vmIsIdle(), FileManager.default.fileExists(atPath: imageURL.path) {
            do {
                try DiskImageVMFeature.grow(imageURL, to: chosenSize)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not resize the disk"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                if let window = sizePopUp.window {
                    alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
        refresh()
    }

    /// Height of the tallest caption, so the window can be sized once. The
    /// wordiest variant is a pending resize; three-digit sizes make it widest.
    /// Measured with a label configured like the real one rather than with
    /// `boundingRect`, which wraps text on its own terms and comes up a line
    /// short.
    private static var tallestNoteHeight: CGFloat {
        let ruler = SettingsLabel.wrappingCaption("")
        ruler.stringValue = noteText(current: 240 * DiskImageSettings.gibibyte,
                                     target: 256 * DiskImageSettings.gibibyte)
        return ceil(ruler.sizeThatFits(
            NSSize(width: SettingsLabel.noteWidth, height: .greatestFiniteMagnitude)).height)
    }

    private static func noteText(current: UInt64?, target: UInt64) -> String {
        let status: String
        if let current, target > current {
            status = "The disk is \(DiskImageSettings.title(for: current)) and grows to "
                + "\(DiskImageSettings.title(for: target)) the next time Home Assistant starts."
        } else if let current {
            status = "The disk is \(DiskImageSettings.title(for: current))."
        } else {
            status = "The disk is created at \(DiskImageSettings.title(for: target)) "
                + "when Home Assistant first starts."
        }
        return status
            + " The disk can be made bigger but not smaller — and no bigger than the free "
            + "space on this Mac. Home Assistant expands its data partition to fill it at its "
            + "next start; the file only takes up what Home Assistant has actually written."
    }
}
