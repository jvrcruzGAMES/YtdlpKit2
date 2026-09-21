import OSLog

enum YtdlpLog {
    static let runtime = Logger(subsystem: "YtdlpKit2", category: "runtime")
    static let python = Logger(subsystem: "YtdlpKit2", category: "python")
    static let filesystem = Logger(subsystem: "YtdlpKit2", category: "filesystem")
    static let bridge = Logger(subsystem: "YtdlpKit2", category: "bridge")
}
