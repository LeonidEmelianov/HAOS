import Foundation

/// Captured on the main queue before preparation: edits in Settings belong to
/// the next run, even when this run is still downloading or editing its disk.
struct VMSettingsSnapshot {
    let cpuCount = VMSettings.cpuCount
    let memorySize = VMSettings.memorySize
    let diskSize = DiskImageSettings.size
    let networkMode = NetworkSettings.mode
    let sharedFolder = SharedFolderSettings.Snapshot()
}
