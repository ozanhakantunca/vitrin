import Foundation
import CoreFoundation

@MainActor
final class CLIServer {
    private let list: () -> [CLIWindow]
    private let focus: (UInt32) -> Bool
    private let show: (String?) -> Bool
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?

    init(list: @escaping () -> [CLIWindow], focus: @escaping (UInt32) -> Bool, show: @escaping (String?) -> Bool) {
        self.list = list
        self.focus = focus
        self.show = show
    }

    /// Retain this server until stop() is called; callbacks run on the main run loop.
    func start() -> Bool {
        if port != nil { return true }
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        var shouldFree = DarwinBoolean(false)
        guard let port = CFMessagePortCreateLocal(nil, CLICoding.portName as CFString, { _, _, data, info in
            guard let info, let data else { return nil }
            return MainActor.assumeIsolated {
                let server = Unmanaged<CLIServer>.fromOpaque(info).takeUnretainedValue()
                let response = server.respond(to: data as Data)
                guard let encoded = try? CLICoding.encode(response) else { return nil }
                return Unmanaged.passRetained(encoded as CFData)
            }
        }, &context, &shouldFree), !shouldFree.boolValue else { return false }
        guard let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else {
            CFMessagePortInvalidate(port)
            return false
        }
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
        source = nil
        port = nil
    }

    deinit {
        if let port { CFMessagePortInvalidate(port) }
        if let source { CFRunLoopSourceInvalidate(source) }
    }

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
