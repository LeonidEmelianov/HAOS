import AppKit
import Virtualization

/// The window showing the guest's display, created the first time it's asked
/// for and kept afterwards — closing it should cost nothing to reopen.
final class ConsoleWindowController {
    private var window: NSWindow?

    /// Shows `virtualMachine`'s display, fronting the window and the app.
    func show(_ virtualMachine: VZVirtualMachine) {
        let window = window ?? makeWindow()
        self.window = window
        (window.contentView as? VZVirtualMachineView)?.virtualMachine = virtualMachine
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let width = CGFloat(DisplayVMFeature.widthInPixels)
        let height = CGFloat(DisplayVMFeature.heightInPixels)

        let vmView = VZVirtualMachineView()
        vmView.capturesSystemKeys = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Home Assistant OS Console"
        // The guest's framebuffer is a fixed size; holding the window to its
        // aspect ratio makes resizing scale the console text instead of
        // letterboxing it.
        window.contentAspectRatio = NSSize(width: width, height: height)
        window.contentView = vmView
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
