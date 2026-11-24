import Foundation

/// Decides whether the process on the other end of a connected socket may talk to us.
typealias CLIPeerVerifier = @Sendable (Int32) -> Bool

enum CLITransportError: Error, Equatable {
    case unsafeDirectory(String)
    case pathTooLong
    case notRunning
    case peerRejected
    case timedOut
    case closed
    case oversizedPayload
    case system(Int32)

    var message: String {
        switch self {
        case .unsafeDirectory(let path):
            return "Refusing to use \(path) for the CLI socket: it must belong to you and allow no group or other access."
        case .pathTooLong: return "The CLI socket path is too long."
        case .notRunning: return "Vitrin is not running. Open Vitrin.app and try again."
        case .peerRejected:
            return "The process serving the Vitrin CLI socket is not this copy of Vitrin; refusing to talk to it."
        case .timedOut, .closed:
            return "Could not reach running Vitrin (request timed out or connection closed). A different Vitrin build may be running."
        case .oversizedPayload: return "Invalid CLI payload: message too large."
        case .system(let code): return "Could not reach running Vitrin (\(String(cString: strerror(code))))."
        }
    }
}

/// Unix domain stream socket used between the `vitrin` CLI and the running app.
/// Frames are a 4-byte big-endian length followed by JSON.
enum CLISocket {
    static let fileName = "vitrin-cli.sock"
    static let timeout: TimeInterval = 2

    /// `<DARWIN_USER_TEMP_DIR>/vitrin-cli.sock`. confstr is used instead of TMPDIR, which callers control.
    static func defaultPath() throws -> String {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { throw CLITransportError.system(errno) }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else { throw CLITransportError.system(errno) }
        return try path(inDirectory: String(cString: buffer))
    }

    /// The socket path inside `directory`, which must be a directory owned by us with no group/other bits.
    static func path(inDirectory directory: String) throws -> String {
        var info = stat()
        guard stat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw CLITransportError.unsafeDirectory(directory) }
        let path = (directory.hasSuffix("/") ? directory : directory + "/") + fileName
        _ = try address(for: path)
        return path
    }

    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw CLITransportError.pathTooLong
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func withSockaddr<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = try address(for: path)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// A blocking, close-on-exec stream socket that never raises SIGPIPE.
    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLITransportError.system(errno) }
        prepare(fd)
        return fd
    }

    static func prepare(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd, SO_SNDTIMEO, timeout)
        setTimeout(fd, SO_RCVTIMEO, timeout)
    }

    private static func setTimeout(_ fd: Int32, _ option: Int32, _ seconds: TimeInterval) {
        let clamped = max(seconds, 0.001)
        var value = timeval(tv_sec: Int(clamped), tv_usec: Int32((clamped - clamped.rounded(.down)) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Connects to `path`; a missing socket or refused connection means the app is not running.
    static func connect(to path: String) throws -> Int32 {
        let fd = try makeSocket()
        let result = try withSockaddr(path) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw code == ENOENT || code == ECONNREFUSED ? CLITransportError.notRunning : CLITransportError.system(code)
        }
        return fd
    }

    /// Client side: connect, verify the server, send one request and read one response.
    static func exchange(_ request: Data, path: String, verifyPeer: CLIPeerVerifier) throws -> Data {
        let fd = try connect(to: path)
        defer { close(fd) }
        guard verifyPeer(fd) else { throw CLITransportError.peerRejected }
        try writeFrame(fd, request, maximumSize: CLICoding.maximumRequestSize)
        return try readFrame(fd, maximumSize: CLICoding.maximumPayloadSize)
    }

    // MARK: Framing

    static func writeFrame(_ fd: Int32, _ payload: Data, maximumSize: Int) throws {
        guard payload.count <= maximumSize else { throw CLITransportError.oversizedPayload }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        let deadline = Date().addingTimeInterval(timeout)
        try frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try checkDeadline(fd, SO_SNDTIMEO, deadline)
                let sent = send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if sent < 0 {
                    if errno == EINTR { continue }
                    throw failure(errno)
                }
                offset += sent
            }
        }
    }

    /// Reads one frame within `timeout` overall, so a client trickling bytes cannot hold the connection.
    static func readFrame(_ fd: Int32, maximumSize: Int) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        let header = try read(fd, count: 4, deadline: deadline)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length <= maximumSize else { throw CLITransportError.oversizedPayload }
        return try read(fd, count: length, deadline: deadline)
    }

    private static func read(_ fd: Int32, count: Int, deadline: Date) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < count {
                try checkDeadline(fd, SO_RCVTIMEO, deadline)
                let received = recv(fd, raw.baseAddress! + offset, count - offset, 0)
                if received < 0 {
                    if errno == EINTR { continue }
                    throw failure(errno)
                }
                if received == 0 { throw CLITransportError.closed }
                offset += received
            }
        }
        return data
    }

    private static func failure(_ code: Int32) -> CLITransportError {
        switch code {
        case EAGAIN: return .timedOut
        case EPIPE, ECONNRESET: return .closed
        default: return .system(code)
        }
    }

    private static func checkDeadline(_ fd: Int32, _ option: Int32, _ deadline: Date) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw CLITransportError.timedOut }
        setTimeout(fd, option, remaining)
    }
}
