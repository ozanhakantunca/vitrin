import os

/// Thin wrapper around `os.Logger` with Vitrin's subsystem.
enum Log {
    static let subsystem = "io.github.ozanhakantunca.vitrin"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let loginItem = Logger(subsystem: subsystem, category: "login-item")
}
