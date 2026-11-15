import Foundation

public enum SecurityError: LocalizedError, Sendable, Equatable {
    case keychain(status: Int32)
    case itemNotFound
    case biometricsUnavailable
    case biometricsDenied
    case invalidBase64(field: String)
    case invalidPublicKey
    case cryptography(String)
    case fileUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Keychain returned status \(status)."
        case .itemNotFound:
            return "The requested keychain item does not exist."
        case .biometricsUnavailable:
            return "Face ID / Touch ID is not available on this device."
        case .biometricsDenied:
            return "Biometric authentication was denied."
        case .invalidBase64(let field):
            return "\(field) is not valid base64."
        case .invalidPublicKey:
            return "The Ed25519 public key is malformed."
        case .cryptography(let detail):
            return "Cryptography failed. \(detail)"
        case .fileUnreadable(let path):
            return "Cannot read file at \(path)."
        }
    }
}