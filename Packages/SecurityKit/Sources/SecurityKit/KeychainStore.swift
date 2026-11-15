import Foundation

/// Keychain facade. One instance per service (e.g. "app.amore.llm"), so two
/// modules can never overwrite each other's keys.
public actor KeychainStore {
    public let service: String
    private let backend: any KeychainBackend
    private let authenticator: any BiometricAuthenticating
    private let defaultAccessibility: KeychainAccessibility

    public init(
        service: String,
        backend: any KeychainBackend = SystemKeychainBackend(),
        authenticator: any BiometricAuthenticating = LocalAuthenticationService(),
        accessibility: KeychainAccessibility = .whenUnlockedThisDeviceOnly
    ) {
        self.service = service
        self.backend = backend
        self.authenticator = authenticator
        self.defaultAccessibility = accessibility
    }

    private func address(_ account: String) -> KeychainAddress {
        KeychainAddress(service: service, account: account)
    }

    // MARK: - Write

    public func set(_ data: Data, for account: String,
                    accessibility: KeychainAccessibility? = nil) throws {
        try backend.insert(data, at: address(account),
                           accessibility: accessibility ?? defaultAccessibility)
    }

    public func setString(_ value: String, for account: String,
                          accessibility: KeychainAccessibility? = nil) throws {
        guard let data = value.data(using: .utf8) else {
            throw SecurityError.cryptography("string is not valid UTF-8")
        }
        try set(data, for: account, accessibility: accessibility)
    }

    // MARK: - Read

    /// Reads raw bytes. When `requireBiometrics` is true the user must pass
    /// Face ID / Touch ID first; a denial throws instead of returning nil so
    /// callers cannot mistake it for "no value".
    public func data(for account: String,
                     requireBiometrics: Bool = false,
                     reason: String = "Unlock to access your saved key") async throws -> Data? {
        if requireBiometrics {
            let ok = try await authenticator.authenticate(reason: reason)
            guard ok else { throw SecurityError.biometricsDenied }
        }
        return try backend.read(at: address(account))
    }

    public func string(for account: String,
                       requireBiometrics: Bool = false,
                       reason: String = "Unlock to access your saved key") async throws -> String? {
        guard let data = try await data(for: account,
                                        requireBiometrics: requireBiometrics,
                                        reason: reason) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw SecurityError.cryptography("stored value is not valid UTF-8")
        }
        return value
    }

    public func hasValue(for account: String) throws -> Bool {
        (try backend.read(at: address(account))) != nil
    }

    // MARK: - Delete

    public func remove(_ account: String) throws {
        try backend.remove(at: address(account))
    }
}