import Foundation
import LocalAuthentication

public protocol BiometricAuthenticating: Sendable {
    func isAvailable() async -> Bool
    /// Returns false when the user cancelled or the policy failed.
    func authenticate(reason: String) async throws -> Bool
}

public struct LocalAuthenticationService: BiometricAuthenticating {
    public init() {}

    public func isAvailable() async -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    public func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw SecurityError.biometricsUnavailable
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch {
            throw SecurityError.biometricsDenied
        }
    }
}

/// Test double: always succeeds.
public struct AlwaysAllowAuthenticator: BiometricAuthenticating {
    public init() {}
    public func isAvailable() async -> Bool { true }
    public func authenticate(reason: String) async throws -> Bool { true }
}

/// Test double: always refuses.
public struct AlwaysDenyAuthenticator: BiometricAuthenticating {
    public init() {}
    public func isAvailable() async -> Bool { true }
    public func authenticate(reason: String) async throws -> Bool { throw SecurityError.biometricsDenied }
}