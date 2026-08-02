import Foundation
import Virtualization

/// One capability of the virtual machine — its disk, its network, the folder
/// shared with it, its console — with everything that capability needs in one
/// place: the settings it reads, the host resources it holds, and the devices
/// it adds to the machine.
///
/// `VMController` builds only the bare machine (CPUs, memory, firmware) and
/// lets the features fill in the rest, so a new capability is a new file next
/// to the others rather than another branch in the controller.
///
/// Every start runs `prepare` on all features and then `configure` on all
/// features, each in the order `VMController` lists them. Every stop — clean
/// shutdown, crash or failed start — runs `tearDown`.
protocol VMFeature: AnyObject {
    /// Host-side work that has to happen before the machine is configured:
    /// downloading the disk image, editing the guest's boot files. Runs off
    /// the main thread and may block for as long as it needs to; throwing
    /// fails the start.
    func prepare(in context: VMFeatureContext) throws

    /// Adds this feature's devices to `configuration`. Devices are appended
    /// rather than assigned, so features can't quietly drop each other's.
    func configure(_ configuration: VZVirtualMachineConfiguration,
                   in context: VMFeatureContext) throws

    /// Releases whatever the feature is holding between runs. Called on every
    /// stop path, so it has to tolerate being called when the feature never
    /// started and when it has already been torn down.
    func tearDown()
}

extension VMFeature {
    func prepare(in context: VMFeatureContext) throws {}
    func tearDown() {}
}

/// What a feature is handed at start: where its files live, and how to say
/// what's taking so long.
struct VMFeatureContext {
    /// ~/Library/Application Support/HAOS — for state that has to survive a
    /// restart (firmware variables, the machine identifier, the vmnet
    /// interface ID).
    let stateDirectory: URL

    /// The guest's disk image. Shared because more than one feature touches
    /// it: one downloads and attaches it, another edits the boot files inside.
    let diskImageURL: URL

    /// Reports ready-to-display progress text while `prepare` runs, for the
    /// menu's status line. Called on the start queue, not the main queue.
    let reportProgress: (String) -> Void
}
