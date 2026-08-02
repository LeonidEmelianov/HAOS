import Foundation

/// Edits the guest's kernel command line, which lives in `cmdline.txt` on the
/// FAT boot partition inside the disk image.
///
/// The guest runs its own bootloader, so the host can't hand it kernel
/// parameters the way it hands it CPUs or memory. Home Assistant OS's GRUB
/// config appends whatever it finds in `cmdline.txt` to the kernel line, and
/// the RAUC update hook copies that file across OS updates — which makes it
/// the one place where a change like this survives.
///
/// The partition is reached by attaching the raw image as a disk device, which
/// requires no privileges but does require that the VM isn't running.
enum GuestBootConfig {
    /// Label of the partition holding the bootloader and `cmdline.txt`.
    private static let bootVolumeName = "hassos-boot"

    /// Adds, replaces or removes one kernel parameter.
    ///
    /// Any existing parameter starting with `prefix` is dropped first, so a
    /// changed value replaces the old one instead of accumulating; passing
    /// `nil` for `parameter` just removes it. The image is left untouched when
    /// the command line already reads the way it should.
    static func setKernelParameter(_ parameter: String?,
                                   replacingPrefix prefix: String,
                                   imagePath: String) throws {
        let image = try attachImage(atPath: imagePath)
        defer { detach(image.wholeDisk) }

        let mountPoint = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HAOS-boot", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/sbin/diskutil", ["mount", "-mountPoint", mountPoint.path, image.bootSlice])
        defer {
            _ = try? run("/usr/sbin/diskutil", ["unmount", mountPoint.path])
            try? FileManager.default.removeItem(at: mountPoint)
        }

        let file = mountPoint.appendingPathComponent("cmdline.txt")
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let updated = commandLine(current, replacingPrefix: prefix, with: parameter)
        guard updated != firstLine(of: current) else { return }
        // Non-atomically, so GRUB keeps reading the same file it always has.
        try (updated + "\n").write(to: file, atomically: false, encoding: .utf8)
        // Extended attributes macOS stamps on the file (provenance, and the
        // like) can't live in FAT, so it spills them into an AppleDouble
        // sidecar. Nothing in the guest wants that on its boot partition.
        try? FileManager.default.removeItem(
            at: file.deletingLastPathComponent()
                .appendingPathComponent("._" + file.lastPathComponent))
    }

    /// The command line GRUB should read, given the one it holds today.
    /// Only the first line counts — GRUB's `file_env` stops at the first
    /// non-printable character — so the rest is dropped.
    static func commandLine(_ current: String,
                            replacingPrefix prefix: String,
                            with parameter: String?) -> String {
        // Splitting on any whitespace, not just spaces: a stray carriage
        // return left on the line would otherwise ride along inside a
        // parameter, and GRUB stops reading at the first unprintable byte.
        var parameters = firstLine(of: current)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.hasPrefix(prefix) }
        if let parameter {
            parameters.append(parameter)
        }
        return parameters.joined(separator: " ")
    }

    private static func firstLine(of text: String) -> String {
        String(text.prefix { !$0.isNewline })
    }

    // MARK: - Disk image

    private struct AttachedImage {
        /// Device for the whole image, e.g. `/dev/disk8`; what `detach` takes.
        let wholeDisk: String
        /// Device for the boot partition, e.g. `/dev/disk8s1`.
        let bootSlice: String
    }

    /// Attaches the raw image without mounting anything, then locates the boot
    /// partition by volume label. Detaches again if the partition isn't there,
    /// so a failure never leaves a device behind.
    private static func attachImage(atPath path: String) throws -> AttachedImage {
        let output = try run("/usr/bin/hdiutil",
                             ["attach", "-imagekey", "diskimage-class=CRawDiskImage",
                              "-nomount", path])
        guard let wholeDisk = output
            .split(separator: "\n")
            .compactMap({ $0.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("/dev/disk") })
        else {
            throw HAOSError("Attaching \(path) produced no disk device")
        }
        do {
            return AttachedImage(wholeDisk: wholeDisk,
                                 bootSlice: try findBootSlice(on: wholeDisk))
        } catch {
            detach(wholeDisk)
            throw error
        }
    }

    private static func findBootSlice(on wholeDisk: String) throws -> String {
        let plist = try run("/usr/sbin/diskutil", ["list", "-plist", wholeDisk])
        let parsed = try PropertyListSerialization.propertyList(
            from: Data(plist.utf8), format: nil) as? [String: Any]
        let partitions = (parsed?["AllDisksAndPartitions"] as? [[String: Any]])?
            .flatMap { $0["Partitions"] as? [[String: Any]] ?? [] } ?? []
        guard let boot = partitions.first(where: { $0["VolumeName"] as? String == bootVolumeName }),
              let identifier = boot["DeviceIdentifier"] as? String
        else {
            throw HAOSError("No \(bootVolumeName) partition on \(wholeDisk)")
        }
        return "/dev/" + identifier
    }

    /// Best-effort: an image that stays attached is a nuisance, not a failure
    /// of the operation that was asked for.
    private static func detach(_ wholeDisk: String) {
        _ = try? run("/usr/bin/hdiutil", ["detach", wholeDisk])
    }

    // MARK: - Subprocesses

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Read before waiting: a pipe that fills up would deadlock the child.
        let standardOutput = output.fileHandleForReading.readDataToEndOfFile()
        let standardError = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw HAOSError("\((launchPath as NSString).lastPathComponent) \(arguments.first ?? "") "
                        + "failed (\(process.terminationStatus)): \(message)")
        }
        return String(data: standardOutput, encoding: .utf8) ?? ""
    }
}
