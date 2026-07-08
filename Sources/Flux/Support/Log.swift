import OSLog

/// Lightweight, unified-logging wrapper. `os.Logger` is effectively free when a
/// log level is disabled, so this adds no measurable overhead at idle.
enum Log {
    private static let subsystem = "com.flux.menubar"

    static let menuBar = Logger(subsystem: subsystem, category: "menubar")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let login = Logger(subsystem: subsystem, category: "login")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
}
