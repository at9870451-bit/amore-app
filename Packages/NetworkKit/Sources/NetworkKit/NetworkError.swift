import Foundation

public enum NetworkError: LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case invalidResponse
    case httpStatus(code: Int, body: String)
    case timeout
    case offline
    case cancelled
    case decoding(String)
    case cache(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value):   return "Invalid URL: \(value)"
        case .invalidResponse:         return "The server returned an unexpected response."
        case .httpStatus(let code, let body):
            let trimmed = body.count > 200 ? String(body.prefix(200)) + "…" : body
            return "HTTP \(code). \(trimmed)"
        case .timeout:                 return "The request timed out."
        case .offline:                 return "You appear to be offline."
        case .cancelled:               return "The request was cancelled."
        case .decoding(let detail):    return "Could not decode the response. \(detail)"
        case .cache(let detail):       return "Cache error. \(detail)"
        case .transport(let detail):   return "Network transport error. \(detail)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .timeout, .offline, .transport:
            return true
        case .httpStatus(let code, _):
            return code == 429 || (500...599).contains(code)
        case .invalidURL, .invalidResponse, .cancelled, .decoding, .cache:
            return false
        }
    }
}