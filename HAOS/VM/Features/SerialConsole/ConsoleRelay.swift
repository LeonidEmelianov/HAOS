import Foundation
import Virtualization
import os

/// Carries the guest's serial console to a Unix socket on the Mac, where a
/// terminal or a script can connect to it — any number at once, each seeing
/// the guest's output and each able to type.
///
/// The guest's side is read whether or not anyone is connected: a console
/// nobody drains fills up, and the CLI behind it stalls mid-write. The last
/// stretch of output is kept and replayed to each new client, so one that
/// connects late still sees the prompt it's answering.
///
/// Everything after `start` runs on the relay's own queue.
final class ConsoleRelay {
    /// How much output a new client is shown: a few screens, enough for the
    /// prompt and what led up to it.
    private static let scrollbackLimit = 16 * 1024

    private let socketPath: String
    private let queue = DispatchQueue(label: "HAOS.ConsoleRelay")

    /// What the guest reads, and what it writes. The relay holds the far
    /// ends as well, for `attachment`.
    private let guestInput = Pipe()
    private let guestOutput = Pipe()

    /// A connected client. Its socket outlives the end of its input: one
    /// that has sent all it will (`printf … | nc -U`) still wants the
    /// guest's answer, so it's closed only once a write to it fails or the
    /// relay stops — and never before its read source's cancel handler has
    /// run, as dispatch requires.
    private final class Client {
        let fd: Int32
        var reader: DispatchSourceRead?
        var readerCancelled = false
        var disconnected = false

        init(fd: Int32) { self.fd = fd }
    }

    private var outputSource: DispatchSourceRead?
    private var listener: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var scrollback = Data()

    /// The guest's end of the line, for its serial port.
    let attachment: VZSerialPortAttachment

    init(socketURL: URL) {
        socketPath = socketURL.path
        attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: guestInput.fileHandleForReading,
            fileHandleForWriting: guestOutput.fileHandleForWriting)
        // A write after the guest's side has closed must fail, not take the
        // app down with SIGPIPE.
        _ = fcntl(guestInput.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// Starts draining the guest's output and listening on the socket. A
    /// socket that can't be made is logged rather than raised: the guest's
    /// side still has to be drained, and the console window still works.
    func start() {
        queue.sync {
            let source = DispatchSource.makeReadSource(
                fileDescriptor: guestOutput.fileHandleForReading.fileDescriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readFromGuest() }
            source.resume()
            outputSource = source

            do {
                try listen()
            } catch {
                log.error("Console socket unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Disconnects every client and removes the socket. Safe to call more
    /// than once, and before `start`.
    func stop() {
        queue.sync {
            outputSource?.cancel()
            outputSource = nil
            if listener != nil {
                listener?.cancel()
                listener = nil
                unlink(socketPath)
            }
            for client in clients.keys {
                disconnect(client)
            }
            scrollback.removeAll()
        }
    }

    // MARK: - Guest

    private func readFromGuest() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(guestOutput.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
        guard count > 0 else {
            // The machine is gone; `stop` is on its way.
            if count == 0 { outputSource?.cancel() }
            return
        }
        let data = Data(buffer[0..<count])
        scrollback.append(data)
        if scrollback.count > Self.scrollbackLimit {
            scrollback.removeFirst(scrollback.count - Self.scrollbackLimit)
        }
        for client in clients.keys {
            send(data, to: client)
        }
    }

    private func writeToGuest(_ bytes: UnsafeRawBufferPointer) {
        let fd = guestInput.fileHandleForWriting.fileDescriptor
        var offset = 0
        while offset < bytes.count {
            let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                return
            }
            offset += written
        }
    }

    // MARK: - Socket

    private func listen() throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw HAOSError("The console socket's path is too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyMemory(from: $0) }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        // A socket file left by a run that crashed would make bind fail.
        unlink(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // The CLI runs as root in the guest; the socket is for this user alone.
        guard bound == 0, chmod(socketPath, 0o600) == 0, Darwin.listen(fd, 4) == 0 else {
            let error = posixError("bind")
            close(fd)
            unlink(socketPath)
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
    }

    private func accept(on listenerFD: Int32) {
        let client = Darwin.accept(listenerFD, nil, nil)
        guard client >= 0 else { return }
        // Fails on a client that hung up before it was accepted, and a write
        // to that one would raise SIGPIPE — so it's dropped right here.
        var on: Int32 = 1
        guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(client)
            return
        }
        // A client that stops reading loses output rather than stalling the
        // guest and every other client.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)

        let state = Client(fd: client)
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        source.setEventHandler { [weak self] in self?.readFromClient(state) }
        source.setCancelHandler {
            state.readerCancelled = true
            if state.disconnected { close(client) }
        }
        source.resume()
        state.reader = source
        clients[client] = state
        send(scrollback, to: client)
    }

    private func readFromClient(_ client: Client) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(client.fd, &buffer, buffer.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else {
            // Nothing more to send, but the client may still be listening.
            client.reader?.cancel()
            client.reader = nil
            return
        }
        buffer[0..<count].withUnsafeBytes { writeToGuest($0) }
    }

    private func send(_ data: Data, to client: Int32) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(client, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno != EAGAIN { disconnect(client) }
                    return
                }
                offset += written
            }
        }
    }

    private func disconnect(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        client.disconnected = true
        if let reader = client.reader {
            client.reader = nil
            reader.cancel()
        } else if client.readerCancelled {
            close(fd)
        }
    }

    private func posixError(_ call: String) -> HAOSError {
        HAOSError("\(call) failed: \(String(cString: strerror(errno)))")
    }
}
