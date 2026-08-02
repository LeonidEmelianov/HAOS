import Foundation
import Virtualization

/// The guest's console: a framebuffer and a keyboard, shown on demand by
/// `ConsoleWindowController`. Home Assistant is used through its web UI, so
/// this is for watching the guest boot and for logging in when the network is
/// the thing that's broken.
final class DisplayVMFeature: VMFeature {
    /// Guest display resolution, in pixels. The console window opens at these
    /// dimensions in *points*, so on a Retina host each framebuffer pixel is
    /// drawn 2x and the Linux console's fixed 8x16 font stays legible. Raising
    /// this shrinks the text: the guest keeps the same glyph size and just
    /// fits more of them on screen.
    static let widthInPixels = 1280
    static let heightInPixels = 800

    func configure(_ configuration: VZVirtualMachineConfiguration,
                   in context: VMFeatureContext) throws {
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: Self.widthInPixels,
                                                 heightInPixels: Self.heightInPixels)
        ]
        configuration.graphicsDevices.append(graphics)
        configuration.keyboards.append(VZUSBKeyboardConfiguration())
    }
}
