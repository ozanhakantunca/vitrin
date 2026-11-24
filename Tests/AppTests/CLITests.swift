import Foundation
import Testing
@testable import Vitrin

private func makeDirectory(mode: mode_t = 0o700) throws -> String {
    var template = Array((NSTemporaryDirectory() + "vcli.XXXXXX").utf8CString)
    let directory = try #require(mkdtemp(&template).map { String(cString: $0) })
    chmod(directory, mode)
    return directory
}

private func exchange(_ data: Data, path: String, verifyPeer: @escaping CLIPeerVerifier = CLIPeerVerification.verify) async throws -> Data {
    try await Task.detached { try CLISocket.exchange(data, path: path, verifyPeer: verifyPeer) }.value
}

private func send(_ request: CLIRequest, path: String) async throws -> CLIResponse {
    try CLICoding.decode(CLIResponse.self, from: await exchange(try CLICoding.encode(request), path: path))
}

/// Writes raw bytes (no client-side framing checks) and reads one response frame.
private func sendRaw(_ bytes: Data, path: String) async throws -> CLIResponse {
    let data = try await Task.detached { () throws -> Data in
        let fd = try CLISocket.connect(to: path)
        defer { close(fd) }
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress!, $0.count, 0) }
        return try CLISocket.readFrame(fd, maximumSize: CLICoding.maximumPayloadSize)
    }.value
    return try CLICoding.decode(CLIResponse.self, from: data)
}

private func frame(_ payload: Data, declaredLength: UInt32? = nil) -> Data {
    var length = (declaredLength ?? UInt32(payload.count)).bigEndian
    return Data(bytes: &length, count: 4) + payload
}

@MainActor private final class Recorder {
    var listCalls = 0
    var focused: [UInt32] = []
    var shown: [String?] = []

    func server(path: String, verifyPeer: @escaping CLIPeerVerifier = CLIPeerVerification.verify) -> CLIServer {
        CLIServer(
            socketPath: { path }, verifyPeer: verifyPeer,
            list: {
                self.listCalls += 1
                return [CLIWindow(id: 7, pid: 42, app: "Finder", title: "Home", minimized: false, hidden: true, fullscreen: false)]
            },
            focus: { self.focused.append($0); return $0 == 7 },
            show: { self.shown.append($0); return $0 != "missing" }
        )
    }
}

@MainActor @Test func cliRoundTripWithRealVerification() async throws {
    let directory = try makeDirectory()
    let path = try CLISocket.path(inDirectory: directory)
    let recorder = Recorder()
    let server = recorder.server(path: path)
    #expect(server.start())
    defer { server.stop() }

    var info = stat()
    #expect(lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK && info.st_mode & 0o777 == 0o600)

    let listed = try await send(CLIRequest(command: .list), path: path)
    #expect(listed.ok && listed.windows?.map(\.id) == [7] && listed.windows?.first?.hidden == true)

    #expect(try await send(CLIRequest(command: .focus, windowID: 7), path: path).ok)
    let missing = try await send(CLIRequest(command: .focus, windowID: 8), path: path)
    #expect(!missing.ok && missing.error == "Window not found or focus failed.")
    #expect(recorder.focused == [7, 8])

    #expect(try await send(CLIRequest(command: .show), path: path).ok)
    #expect(try await send(CLIRequest(command: .show, profileID: "work"), path: path).ok)
    #expect(try await !send(CLIRequest(command: .show, profileID: "missing"), path: path).ok)
    #expect(recorder.shown == [nil, "work", "missing"])
    #expect(recorder.listCalls == 1)

    server.stop()
    #expect(lstat(path, &info) != 0)
    await #expect(throws: CLITransportError.notRunning) { try await send(CLIRequest(command: .list), path: path) }
}

@MainActor @Test func cliRejectedPeerGetsNoData() async throws {
    let path = try CLISocket.path(inDirectory: makeDirectory())
    let recorder = Recorder()
    let server = recorder.server(path: path, verifyPeer: { _ in false })
    #expect(server.start())
    defer { server.stop() }

    await #expect(throws: CLITransportError.closed) {
        try await exchange(try CLICoding.encode(CLIRequest(command: .list)), path: path)
    }
    #expect(recorder.listCalls == 0)
}

@MainActor @Test func cliClientRejectsUnverifiedServer() async throws {
    let path = try CLISocket.path(inDirectory: makeDirectory())
    let recorder = Recorder()
    let server = recorder.server(path: path)
    #expect(server.start())
    defer { server.stop() }

    await #expect(throws: CLITransportError.peerRejected) {
        try await exchange(try CLICoding.encode(CLIRequest(command: .list)), path: path, verifyPeer: { _ in false })
    }
    #expect(recorder.listCalls == 0)
}

@MainActor @Test func cliOversizedRequest() async throws {
    let path = try CLISocket.path(inDirectory: makeDirectory())
    let recorder = Recorder()
    let server = recorder.server(path: path)
    #expect(server.start())
    defer { server.stop() }

    let response = try await sendRaw(frame(Data(), declaredLength: UInt32(CLICoding.maximumRequestSize + 1)), path: path)
    #expect(!response.ok && response.error == "CLI request too large.")
    await #expect(throws: CLITransportError.oversizedPayload) {
        try await exchange(Data(count: CLICoding.maximumRequestSize + 1), path: path)
    }
    #expect(recorder.listCalls == 0)
}

@MainActor @Test func cliMalformedRequest() async throws {
    let path = try CLISocket.path(inDirectory: makeDirectory())
    let recorder = Recorder()
    let server = recorder.server(path: path)
    #expect(server.start())
    defer { server.stop() }

    for payload in ["not json", #"{"command":"focus"}"#, #"{"command":"list","windowID":3}"#, #"{"command":"show","profileID":""}"#] {
        let response = try await sendRaw(frame(Data(payload.utf8)), path: path)
        #expect(!response.ok && response.error == "Invalid CLI request.")
    }
    #expect(recorder.listCalls == 0 && recorder.focused.isEmpty && recorder.shown.isEmpty)
}

@MainActor @Test func cliSocketPathChecks() throws {
    let open = try makeDirectory(mode: 0o755)
    #expect(throws: CLITransportError.unsafeDirectory(open)) { try CLISocket.path(inDirectory: open) }
    let groupWritable = try makeDirectory(mode: 0o720)
    #expect(throws: CLITransportError.unsafeDirectory(groupWritable)) { try CLISocket.path(inDirectory: groupWritable) }
    #expect(throws: CLITransportError.unsafeDirectory("/no/such/dir")) { try CLISocket.path(inDirectory: "/no/such/dir") }
    #expect(throws: CLITransportError.unsafeDirectory("/")) { try CLISocket.path(inDirectory: "/") } // owned by root

    let directory = try makeDirectory()
    #expect(try CLISocket.path(inDirectory: directory) == directory + "/vitrin-cli.sock")
    #expect(try CLISocket.defaultPath().hasSuffix("/vitrin-cli.sock"))
    #expect(throws: CLITransportError.pathTooLong) { try CLISocket.address(for: "/" + String(repeating: "a", count: 104)) }

    let unsafeServer = CLIServer(
        socketPath: { try CLISocket.path(inDirectory: open) }, verifyPeer: { _ in true },
        list: { [] }, focus: { _ in false }, show: { _ in false }
    )
    #expect(!unsafeServer.start())
}

@MainActor @Test func cliServerReplacesOnlyStaleSockets() async throws {
    let directory = try makeDirectory()
    let path = try CLISocket.path(inDirectory: directory)

    // A regular file at the path is never removed.
    #expect(FileManager.default.createFile(atPath: path, contents: Data("keep".utf8)))
    #expect(!Recorder().server(path: path).start())
    #expect(FileManager.default.contents(atPath: path) == Data("keep".utf8))
    unlink(path)

    // A stale socket (nobody listening) is replaced.
    let stale = try CLISocket.makeSocket()
    #expect(try CLISocket.withSockaddr(path) { bind(stale, $0, $1) } == 0)
    close(stale)
    let server = Recorder().server(path: path)
    #expect(server.start())
    defer { server.stop() }
    #expect(try await send(CLIRequest(command: .list), path: path).ok)

    // A live server is not taken over.
    #expect(!Recorder().server(path: path).start())
    #expect(try await send(CLIRequest(command: .list), path: path).ok)

    // A listener that is not Vitrin is replaced.
    let replacement = Recorder().server(path: path, verifyPeer: { _ in false })
    #expect(replacement.start())
    replacement.stop()
}
