import Foundation
import OSLog

/// Thin wrapper around `OSLog` so every module logs under one subsystem with
/// its own category. Call sites pass interpolated values with explicit
/// privacy (`privacy: .private` for anything user-authored).
public struct AmoreLogger: Sendable {
    public let category: String
    private let logger: Logger

    public init(category: String, subsystem: String = "app.amore") {
        self.category = category
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    /// Redacts user content before it reaches the system log.
    public static func redacted(_ value: String) -> String {
        value.isEmpty ? "<empty>" : "<\(value.count) chars>"
    }
}