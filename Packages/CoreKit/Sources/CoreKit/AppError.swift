import Foundation

/// One error type shared by every module. Domain modules add detail in the
/// associated message rather than inventing incompatible shapes.
public enum AppError: LocalizedError, Sendable, Equatable {
    case cancelled
    case unauthorized(String)
    case network(String)
    case decoding(String)
    case notFound(String)
    case invalidInput(String)
    case plugin(String)
    case storage(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The operation was cancelled."
        case .unauthorized(let detail):
            return "Not authorized. \(detail)"
        case .network(let detail):
            return "Network error. \(detail)"
        case .decoding(let detail):
            return "Could not read the response. \(detail)"
        case .notFound(let detail):
            return "Not found. \(detail)"
        case .invalidInput(let detail):
            return "Invalid input. \(detail)"
        case .plugin(let detail):
            return "Plugin error. \(detail)"
        case .storage(let detail):
            return "Storage error. \(detail)"
        case .unknown(let detail):
            return detail.isEmpty ? "Something went wrong." : detail
        }
    }

    /// Compact code for logs and diagnostics exports — never user-facing text.
    public var code: String {
        switch self {
        case .cancelled:  return "cancelled"
        case .unauthorized: return "unauthorized"
        case .network:    return "network"
        case .decoding:   return "decoding"
        case .notFound:   return "not_found"
        case .invalidInput: return "invalid_input"
        case .plugin:     return "plugin"
        case .storage:    return "storage"
        case .unknown:    return "unknown"
        }
    }
}