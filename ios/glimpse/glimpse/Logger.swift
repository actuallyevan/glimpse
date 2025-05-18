import OSLog

private var logEnabled = false

extension Logger {
    
    private static let _logger: Logger = .init(subsystem: Bundle.main.bundleIdentifier!, category: "glimpse")
    static var logger: Logger? {
        guard logEnabled else { return nil }
        return _logger
    }
}
