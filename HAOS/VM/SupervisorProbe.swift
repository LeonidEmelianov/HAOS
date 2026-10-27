import Foundation

/// Says what the Supervisor is busy with while it hasn't finished setting up.
///
/// Until the Supervisor is through its setup it starts nothing — Home
/// Assistant included — and refuses the CLI with "System is not ready with
/// state: setup". Setup is seconds on a normal boot, but it waits out any
/// image it finds missing, and a large one on a slow line takes long enough
/// to look like a hang; restarting the guest then only starts the download
/// over. The Supervisor's API is only reachable inside the guest, but the
/// Observer it runs on port 4357 is on the network and shows the two things
/// that tell: "Processing…" where the support and health verdicts go, for as
/// long as the Supervisor refuses to give them, and — only then — the
/// Supervisor's log.
final class SupervisorProbe {
    /// How often to ask. The Observer page is a few dozen KB of log.
    private static let interval: TimeInterval = 5

    /// What the Observer shows in place of a verdict the Supervisor can't
    /// give yet.
    private static let pendingMarker = "Processing..."

    /// The Supervisor's first log line on each start; what came before it
    /// belongs to an earlier run.
    private static let startMarker = "Initializing Supervisor setup"

    /// The lines that name an image setup is waiting for: the download
    /// itself, and the line that leads to it. The Observer copies the log
    /// through a buffer it never flushes, so the last few KB never reach the
    /// page — and while setup sits on a download, the download's own line is
    /// usually among them. The one before it isn't.
    private static let imageLine = try! Regex(
        #"(?:Downloading docker image|No \S+ app Docker image) (\S+)"#)

    private let url: URL
    private let session: URLSession

    /// Identifies the current run, as in `WebUIProbe`.
    private var generation = 0
    private var lastActivity: String??

    init(observerURL: URL) {
        url = observerURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
    }

    /// Polls until stopped, reporting each change on the main queue: a
    /// sentence for the status line while the Supervisor is setting up, nil
    /// once it isn't or can't be asked. Must be called on the main queue.
    func start(_ handler: @escaping (String?) -> Void) {
        generation += 1
        lastActivity = nil
        probe(generation: generation, handler: handler)
    }

    /// Ends the polling; nothing is reported after this returns. Safe to call
    /// when the probe isn't running.
    func stop() {
        generation += 1
    }

    private func probe(generation: Int, handler: @escaping (String?) -> Void) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                var activity: String?
                if (response as? HTTPURLResponse)?.statusCode == 200, let data {
                    activity = Self.activity(onPage: String(decoding: data, as: UTF8.self))
                }
                if self.lastActivity != .some(activity) {
                    self.lastActivity = .some(activity)
                    handler(activity)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.interval) {
                    self.probe(generation: generation, handler: handler)
                }
            }
        }.resume()
    }

    /// The status-line sentence for an Observer page, nil when the
    /// Supervisor has finished setting up.
    static func activity(onPage page: String) -> String? {
        let parts = page.components(separatedBy: "<pre")
        guard parts[0].contains(pendingMarker) else { return nil }
        let log = parts.dropFirst().joined()
        let currentRun = log.range(of: startMarker, options: .backwards)
            .map { log[$0.upperBound...] } ?? Substring(log)
        guard let match = currentRun.matches(of: imageLine).last,
              let image = match.output[1].substring else {
            return "the Supervisor is setting up…"
        }
        // `ghcr.io/music-assistant/server` reads better without the registry.
        var components = image.split(separator: "/")
        if components.count > 1, components[0].contains(".") {
            components.removeFirst()
        }
        return "the Supervisor is downloading \(components.joined(separator: "/")); "
            + "Home Assistant starts once it's done"
    }
}
