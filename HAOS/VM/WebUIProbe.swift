import Foundation

/// Watches for Home Assistant's web UI to come up behind a running guest.
///
/// The guest is on the network long before Home Assistant is, and the app
/// has no channel into the guest to ask — so it asks the way a browser
/// would. While the Supervisor is still downloading Home Assistant it serves
/// a placeholder on the same port, one that proxies `/api/` to the
/// Supervisor and so answers it with the same 401 Home Assistant would. The
/// page itself is what tells them apart: the placeholder is built around a
/// `<ha-landing-page>` element, which Home Assistant's frontend never shows.
final class WebUIProbe {
    enum Sighting {
        /// Nothing listens on the web UI port.
        case nothing
        /// The Supervisor's placeholder: Home Assistant is being installed.
        case placeholder
        /// Home Assistant itself.
        case homeAssistant
    }

    /// How often to ask while the answer is still no.
    private static let interval: TimeInterval = 3

    /// The text that marks the placeholder's page.
    private static let placeholderMarker = "ha-landing-page"

    private let url: URL
    private let session: URLSession

    /// Identifies the current run: a response or timer from a run that's
    /// been stopped compares unequal and is dropped.
    private var generation = 0
    private var lastSighting: Sighting?

    init(webUIURL: URL) {
        url = webUIURL
        let configuration = URLSessionConfiguration.ephemeral
        // mDNS takes a moment to resolve a guest that has only just
        // appeared; a stuck request must still give way to the next.
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
    }

    /// Polls until Home Assistant answers, reporting each change in what
    /// does on the main queue. Must be called on the main queue.
    func start(_ handler: @escaping (Sighting) -> Void) {
        generation += 1
        lastSighting = nil
        probe(generation: generation, handler: handler)
    }

    /// Ends the polling; nothing is reported after this returns. Safe to call
    /// when the probe isn't running.
    func stop() {
        generation += 1
    }

    private func probe(generation: Int, handler: @escaping (Sighting) -> Void) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                let sighting: Sighting
                if response as? HTTPURLResponse == nil {
                    sighting = .nothing
                } else if let data, String(decoding: data, as: UTF8.self)
                            .contains(Self.placeholderMarker) {
                    sighting = .placeholder
                } else {
                    sighting = .homeAssistant
                }
                if sighting != self.lastSighting {
                    self.lastSighting = sighting
                    handler(sighting)
                }
                guard sighting != .homeAssistant else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.interval) {
                    self.probe(generation: generation, handler: handler)
                }
            }
        }.resume()
    }
}
