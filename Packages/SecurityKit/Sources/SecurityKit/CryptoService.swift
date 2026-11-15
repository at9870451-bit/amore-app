import CryptoKit
import Foundation

/// Hash and signature helpers. Stateless and `Sendable`; no keys are kept here
/// — they live in `KeychainStore`.
public struct CryptoService: Sendable {
    public init() {}

    // MARK: - SHA-256

    public func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public func sha256Hex(_ data: Data) -> String {
        sha256(data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streaming hash for large files: reads 1 MiB at a time so a 500 MB
    /// download never lands in memory.
    public func sha256(fileAt url: URL) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SecurityError.fileUnreadable(url.lastPathComponent)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1 << 20
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw SecurityError.fileUnreadable(url.lastPathComponent)
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    public func sha256FileHex(_ url: URL) throws -> String {
        try sha256(fileAt: url).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Ed25519

    /// Verifies a base64 signature over `data` with a base64 raw public key
    /// (32 bytes). Returns false for a well-formed but invalid signature;
    /// throws only when the inputs themselves cannot be decoded.
    public func verifyEd25519(
        signatureBase64: String,
        data: Data,
        publicKeyBase64: String
    ) throws -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64) else {
            throw SecurityError.invalidBase64(field: "signature")
        }
        guard let keyData = Data(base64Encoded: publicKeyBase64) else {
            throw SecurityError.invalidBase64(field: "publicKey")
        }
        return try verifyEd25519(signature: signature, data: data, publicKey: keyData)
    }

    public func verifyEd25519(signature: Data, data: Data, publicKey: Data) throws -> Bool {
        guard publicKey.count == 32 else { throw SecurityError.invalidPublicKey }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            throw SecurityError.invalidPublicKey
        }
        return key.isValidSignature(signature, for: data)
    }
}