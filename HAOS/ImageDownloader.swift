import Foundation
import Compression

/// Downloads the latest Home Assistant OS disk image from GitHub when none
/// exists locally: resolves the newest release, fetches the
/// haos_generic-aarch64-*.img.xz asset, decompresses it in-process (Apple's
/// Compression framework decodes the xz container), and moves the result to
/// its final path. VMController grows the image to its full virtual disk
/// size before attaching it.
final class ImageDownloader: NSObject, URLSessionDownloadDelegate {
    private let releasesAPI = URL(string: "https://api.github.com/repos/home-assistant/operating-system/releases/latest")!

    /// Final resting place of the decompressed disk image.
    private let destination: URL

    private var progress: ((String) -> Void)?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var lastReportedPercent = -1

    /// The session retains `self` as its delegate until
    /// `finishTasksAndInvalidate()` in `finish`, which keeps the downloader
    /// alive for the duration of the transfer.
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // The compressed image is several hundred MB; allow slow connections.
        configuration.timeoutIntervalForResource = 4 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Creates a downloader that will install the disk image at `destination`.
    init(destination: URL) {
        self.destination = destination
    }

    /// Resolves the latest release and downloads its image. `progress`
    /// receives ready-to-display status text; both callbacks arrive on
    /// arbitrary background queues.
    func downloadLatestImage(progress: @escaping (String) -> Void,
                             completion: @escaping (Result<Void, Error>) -> Void) {
        self.progress = progress
        self.completion = completion
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        progress("Finding latest release…")
        let task = session.dataTask(with: releasesAPI) { [weak self] data, _, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let data,
                  let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = release["assets"] as? [[String: Any]] else {
                self.finish(.failure(Self.error("Could not parse the GitHub release feed")))
                return
            }
            guard let asset = assets.first(where: { asset in
                guard let name = asset["name"] as? String else { return false }
                return name.hasPrefix("haos_generic-aarch64-") && name.hasSuffix(".img.xz")
            }), let urlString = asset["browser_download_url"] as? String,
               let downloadURL = URL(string: urlString) else {
                self.finish(.failure(Self.error("No generic-aarch64 image in the latest release")))
                return
            }
            self.progress?("Downloading image… 0%")
            self.session.downloadTask(with: downloadURL).resume()
        }
        task.resume()
    }

    /// Delivers the result exactly once and lets the session release `self`.
    private func finish(_ result: Result<Void, Error>) {
        session.finishTasksAndInvalidate()
        completion?(result)
        completion = nil
        progress = nil
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "HAOSMenuBar", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
        if percent != lastReportedPercent {
            lastReportedPercent = percent
            progress?("Downloading image… \(percent)%")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` is deleted when this callback returns, and decompression
        // takes a while — claim the file first.
        let compressed = destination.appendingPathExtension("xz")
        let partial = destination.appendingPathExtension("partial")
        do {
            try? FileManager.default.removeItem(at: compressed)
            try FileManager.default.moveItem(at: location, to: compressed)
            defer { try? FileManager.default.removeItem(at: compressed) }

            try? FileManager.default.removeItem(at: partial)
            try decompressXZ(from: compressed, to: partial)

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
            finish(.success(()))
        } catch {
            try? FileManager.default.removeItem(at: partial)
            finish(.failure(error))
        }
    }

    // MARK: - xz decompression

    /// Streams `source` through Compression's LZMA decoder into `output`,
    /// reporting progress against the compressed size (the decompressed size
    /// isn't known up front).
    private func decompressXZ(from source: URL, to output: URL) throws {
        let totalBytes = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? Int64
        let input = try FileHandle(forReadingFrom: source)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: output)
        defer {
            try? input.close()
            try? outputHandle.close()
        }

        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA)
                == COMPRESSION_STATUS_OK else {
            throw Self.error("Could not initialize xz decompression")
        }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 1 << 20
        let sourceBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        let destBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            sourceBuffer.deallocate()
            destBuffer.deallocate()
        }

        var consumedBytes: Int64 = 0
        var flags: Int32 = 0
        var status = COMPRESSION_STATUS_OK
        while status == COMPRESSION_STATUS_OK {
            if stream.src_size == 0 && flags == 0 {
                let chunk = try input.read(upToCount: bufferSize) ?? Data()
                chunk.copyBytes(to: sourceBuffer, count: chunk.count)
                stream.src_ptr = UnsafePointer(sourceBuffer)
                stream.src_size = chunk.count
                if chunk.isEmpty {
                    flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                }
                consumedBytes += Int64(chunk.count)
                if let totalBytes, totalBytes > 0 {
                    let percent = Int(consumedBytes * 100 / totalBytes)
                    if percent != lastReportedPercent {
                        lastReportedPercent = percent
                        progress?("Unpacking image… \(percent)%")
                    }
                }
            }
            stream.dst_ptr = destBuffer
            stream.dst_size = bufferSize
            status = compression_stream_process(&stream, flags)
            guard status != COMPRESSION_STATUS_ERROR else {
                throw Self.error("The downloaded image failed to decompress")
            }
            let produced = bufferSize - stream.dst_size
            if produced > 0 {
                try outputHandle.write(contentsOf: Data(bytesNoCopy: destBuffer, count: produced,
                                                        deallocator: .none))
            }
        }
    }
}
