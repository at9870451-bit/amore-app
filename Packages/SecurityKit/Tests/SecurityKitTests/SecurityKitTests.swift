import CryptoKit
import Foundation
import Testing

@testable import SecurityKit

@Suite("CryptoService")
struct CryptoServiceTests {
    let service = CryptoService()

    @Test("SHA-256 matches the known vector for 'abc'")
    func sha256Vector() {
        let digest = service.sha256Hex(Data("abc".utf8))
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("streaming file hash matches the in-memory hash")
    func streamingFileHash() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amore-hash-\(UUID().uuidString).bin")
        let payload = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let streamed = try service.sha256FileHex(url)
        #expect(streamed == service.sha256Hex(payload))
    }

    @Test("missing file throws fileUnreadable")
    func missingFile() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")
        #expect(throws: SecurityError.self) {
            _ = try service.sha256(fileAt: url)
        }
    }

    @Test("valid Ed25519 signature verifies")
    func signatureSuccess() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let message = Data("amore-plugin-payload".utf8)
        let signature = try privateKey.signature(for: message)

        let ok = try service.verifyEd25519(
            signatureBase64: signature.base64EncodedString(),
            data: message,
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )
        #expect(ok)
    }

    @Test("tampered payload fails verification")
    func signatureFailure() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signature = try privateKey.signature(for: Data("original".utf8))
        let ok = try service.verifyEd25519(
            signatureBase64: signature.base64EncodedString(),
            data: Data("tampered".utf8),
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )
        #expect(!ok)
    }

    @Test("malformed base64 is rejected, not treated as a bad signature")
    func invalidBase64() {
        #expect(throws: SecurityError.invalidBase64(field: "signature")) {
            _ = try service.verifyEd25519(
                signatureBase64: "not base64!!",
                data: Data(),
                publicKeyBase64: Data(repeating: 0, count: 32).base64EncodedString()
            )
        }
    }

    @Test("wrong-length public key is rejected")
    func invalidPublicKey() {
        #expect(throws: SecurityError.invalidPublicKey) {
            _ = try service.verifyEd25519(
                signature: Data(repeating: 0, count: 64),
                data: Data(),
                publicKey: Data(repeating: 0, count: 16)
            )
        }
    }
}

@Suite("KeychainStore")
struct KeychainStoreTests {
    @Test("round-trips a value inside its own service")
    func roundTrip() async throws {
        let store = KeychainStore(service: "app.amore.test", backend: InMemoryKeychainBackend())
        try await store.setString("sk-test-123", for: "openai")

        let value = try await store.string(for: "openai")
        let hasValue = try await store.hasValue(for: "openai")
        #expect(value == "sk-test-123")
        #expect(hasValue)
    }

    @Test("services are isolated from each other")
    func serviceIsolation() async throws {
        let backend = InMemoryKeychainBackend()
        let a = KeychainStore(service: "app.amore.a", backend: backend)
        let b = KeychainStore(service: "app.amore.b", backend: backend)

        try await a.setString("value-a", for: "token")
        let other = try await b.string(for: "token")
        #expect(other == nil)
    }

    @Test("removal makes the value disappear")
    func removal() async throws {
        let store = KeychainStore(service: "app.amore.test", backend: InMemoryKeychainBackend())
        try await store.setString("x", for: "k")
        try await store.remove("k")
        let remaining = try await store.string(for: "k")
        #expect(remaining == nil)
    }

    @Test("biometrics required and denied throws instead of returning nil")
    func biometricDenied() async throws {
        let store = KeychainStore(
            service: "app.amore.test",
            backend: InMemoryKeychainBackend(),
            authenticator: AlwaysDenyAuthenticator()
        )
        try await store.setString("secret", for: "k")

        await #expect(throws: SecurityError.biometricsDenied) {
            _ = try await store.string(for: "k", requireBiometrics: true)
        }
    }

    @Test("biometrics required and allowed returns the value")
    func biometricAllowed() async throws {
        let store = KeychainStore(
            service: "app.amore.test",
            backend: InMemoryKeychainBackend(),
            authenticator: AlwaysAllowAuthenticator()
        )
        try await store.setString("secret", for: "k")
        let value = try await store.string(for: "k", requireBiometrics: true)
        #expect(value == "secret")
    }
}