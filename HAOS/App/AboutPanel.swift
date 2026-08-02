import AppKit

/// The standard about panel. AppKit renders the app icon, name and version
/// from the bundle, so only the credits blurb is ours.
enum AboutPanel {
    static func show() {
        // An accessory app has to activate itself first, or the panel opens
        // behind whatever the user was in.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// What the app does, plus a link to the upstream image the VM boots.
    private static let credits: NSAttributedString = {
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
}
