import Foundation
import VitrinCore
import CoreFoundation

enum CLI {
    static let help = """
    Usage: vitrin <command>
      list [--json]     List windows in MRU order (id, app, title, flags).
      focus <windowID>  Focus a window in the running Vitrin.
      show [profileID]  Open the switcher using the default or named profile.
      --version         Print the installed version.
      --help            Show this help.
    Window commands require Vitrin to be running.
    """

    /// Arguments include argv[0], matching CommandLine.arguments.
    static func runIfRequested(arguments: [String]) -> Int32? {
        let args = Array(arguments.dropFirst())
        guard let command = args.first else { return nil }
        // Preserve the `--dump-windows` diagnostic entry point.
        if command == "--dump-windows" { return nil }
        if args == ["--help"] || args == ["-h"] { print(help); return 0 }
        if args == ["--version"] {
            print("Vitrin \(installedVersion())")
            return 0
        }
        let request: CLIRequest
        switch command {
        case "list" where args.count == 1 || args == ["list", "--json"]:
            request = CLIRequest(command: .list)
        case "focus" where args.count == 2:
            guard let id = UInt32(args[1]), id > 0 else { return fail("windowID must be a positive UInt32.") }
            request = CLIRequest(command: .focus, windowID: id)
        case "show" where args.count <= 2:
            guard args.count == 1 || (!args[1].isEmpty && !args[1].hasPrefix("-")) else { return fail("Invalid profileID.") }
            request = CLIRequest(command: .show, profileID: args.count == 2 ? args[1] : nil)
        default: return fail("Invalid command or arguments.\n\(help)")
        }
        guard let port = CFMessagePortCreateRemote(nil, CLICoding.portName as CFString) else {
            return fail("Vitrin is not running. Open Vitrin.app and try again.")
        }
        do {
            let data = try CLICoding.encode(request)
            var reply: Unmanaged<CFData>?
            let status = CFMessagePortSendRequest(port, 1, data as CFData, 2, 2, CFRunLoopMode.defaultMode.rawValue, &reply)
            guard status == kCFMessagePortSuccess, let responseData = reply?.takeRetainedValue() else {
                return fail("Could not reach running Vitrin (transport status \(status); request timed out or connection closed).")
            }
            let response = try CLICoding.decode(CLIResponse.self, from: responseData as Data)
            guard response.ok else { return fail(response.error ?? "Vitrin could not perform the command.") }
            if command == "list" {
                guard let windows = response.windows else { return fail("Invalid response: missing windows.") }
                if args.contains("--json") {
                    print(String(decoding: try CLICoding.encode(windows), as: UTF8.self))
                } else {
                    print("ID\tAPP\tTITLE\tFLAGS")
                    for window in windows {
                        let flags = [(window.minimized ? "minimized" : nil), (window.hidden ? "hidden" : nil), (window.fullscreen ? "fullscreen" : nil)].compactMap { $0 }.joined(separator: ",")
                        let app = window.app.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                        let title = window.title.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                        print("\(window.id)\t\(app)\t\(title)\t\(flags.isEmpty ? "-" : flags)")
                    }
                }
            }
            return 0
        } catch { return fail("Invalid CLI payload: \(error)") }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("vitrin: \(message)\n".utf8))
        return 1
    }
}

extension CLI {
    /// The version of the app bundle this executable lives in. The CLI usually runs through a
    /// symlink (~/.local/bin/vitrin), so resolve it before looking for Contents/Info.plist.
    static func installedVersion() -> String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        if let info = NSDictionary(contentsOf: plist), let version = info["CFBundleShortVersionString"] as? String {
            return version
        }
        return "\(VitrinCore.version) (unbundled)"
    }
}
