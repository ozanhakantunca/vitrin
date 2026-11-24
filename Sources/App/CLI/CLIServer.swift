import Foundation

@MainActor
final class CLIServer {
    private let list: () -> [CLIWindow]
    private let focus: (UInt32) -> Bool
    private let show: (String?) -> Bool
    private let socketPath: () throws -> String
    private let verifyPeer: CLIPeerVerifier
    private var listener: CLIListener?

    convenience init(list: @escaping () -> [CLIWindow], focus: @escaping (UInt32) -> Bool, show: @escaping (String?) -> Bool) {
        self.init(socketPath: CLISocket.defaultPath, verifyPeer: CLIPeerVerification.verify, list: list, focus: focus, show: show)
    }

    /// Tests inject the socket path and the peer check.
    init(
        socketPath: @escaping () throws -> String, verifyPeer: @escaping CLIPeerVerifier,
        list: @escaping () -> [CLIWindow], focus: @escaping (UInt32) -> Bool, show: @escaping (String?) -> Bool
    ) {
        self.socketPath = socketPath
        self.verifyPeer = verifyPeer
        self.list = list
        self.focus = focus
        self.show = show
    }

    /// Retain this server until stop() is called; commands run on the main actor.
    func start() -> Bool {
        if listener != nil { return true }
        guard let path = try? socketPath() else { return false }
        let listener = CLIListener(path: path, verifyPeer: verifyPeer) { [weak self] data in
            guard let self else { return nil }
            return try? CLICoding.encode(self.respond(to: data))
        }
        guard listener.start() else { return false }
        self.listener = listener
        return true
    }

    func stop() {
        listener?.stop()
        listener = nil
    }

    deinit { listener?.stop() }

    private func respond(to data: Data) -> CLIResponse {
        do {
            let request = try CLICoding.decodeRequest(data)
            switch request.command {
            case .list: return CLIResponse(ok: true, windows: list())
            case .focus:
                let success = focus(request.windowID!) // validated by decodeRequest
                return CLIResponse(ok: success, error: success ? nil : "Window not found or focus failed.")
            case .show:
                let success = show(request.profileID)
                return CLIResponse(ok: success, error: success ? nil : "Profile unavailable or switcher could not open.")
            }
        } catch { return CLIResponse(ok: false, error: "Invalid CLI request.") }
    }
}

/// Owns the listening socket. Accepting runs on a private queue and each connection on its own
/// work item, so slow clients never block the main thread or each other beyond the I/O timeouts.
private final class CLIListener: @unchecked Sendable {
    typealias Responder = @MainActor (Data) -> Data?

    private static let maximumConnections = 8
    private let path: String
    private let verifyPeer: CLIPeerVerifier
    private let respond: Responder
    private let acceptQueue = DispatchQueue(label: "io.github.ozanhakantunca.vitrin.cli.accept")
    private let connectionQueue = DispatchQueue(label: "io.github.ozanhakantunca.vitrin.cli.connection", attributes: .concurrent)
    private let lock = NSLock()
    private var activeConnections = 0
    private var source: DispatchSourceRead?

    init(path: String, verifyPeer: @escaping CLIPeerVerifier, respond: @escaping Responder) {
        self.path = path
        self.verifyPeer = verifyPeer
        self.respond = respond
    }

    func start() -> Bool {
        // A running Vitrin already serves the path: leave it alone. Any other listener is replaced.
        if let probe = try? CLISocket.connect(to: path) {
            let isVitrin = verifyPeer(probe)
            close(probe)
            if isVitrin { return false }
        }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, unlink(path) == 0 else { return false }
        }
        guard let fd = try? CLISocket.makeSocket() else { return false }
        let bound = (try? CLISocket.withSockaddr(path) { bind(fd, $0, $1) }) == 0
        guard bound, chmod(path, 0o600) == 0, listen(fd, 16) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0
        else {
            close(fd)
            if bound { unlink(path) }
            return false
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
        return true
    }

    func stop() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        unlink(path)
    }

    private func acceptPending(on listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return } // EAGAIN: drained
            CLISocket.prepare(fd)
            guard reserveConnection() else { close(fd); continue }
            connectionQueue.async { self.serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        guard verifyPeer(fd) else { finish(fd); return } // rejected peers get no data
        let reply: Data?
        do {
            let request = try CLISocket.readFrame(fd, maximumSize: CLICoding.maximumRequestSize)
            DispatchQueue.main.async {
                let response = MainActor.assumeIsolated { self.respond(request) }
                self.connectionQueue.async { self.write(response, to: fd) }
            }
            return
        } catch CLITransportError.oversizedPayload {
            reply = try? CLICoding.encode(CLIResponse(ok: false, error: "CLI request too large."))
        } catch {
            reply = nil
        }
        write(reply, to: fd)
    }

    private func write(_ response: Data?, to fd: Int32) {
        if let response { try? CLISocket.writeFrame(fd, response, maximumSize: CLICoding.maximumPayloadSize) }
        finish(fd)
    }

    private func finish(_ fd: Int32) {
        close(fd)
        lock.lock()
        activeConnections -= 1
        lock.unlock()
    }

    private func reserveConnection() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeConnections < Self.maximumConnections else { return false }
        activeConnections += 1
        return true
    }
}
