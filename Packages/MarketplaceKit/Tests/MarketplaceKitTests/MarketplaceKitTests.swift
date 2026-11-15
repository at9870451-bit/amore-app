import CryptoKit
import Foundation
import Testing
import ZIPFoundation

@testable import MarketplaceKit
import PluginKit
import SecurityKit

private let manifestJSON = """
{
  "schemaVersion": 1,
  "id": "io.github.alice.echo",
  "name": "Echo",
  "version": "1.0.0",
  "minHostVersion": "1.0.0",
  "type": "js",
  "entry": "index.js",
  "author": { "name": "Alice" },
  "description": "echo",
  "permissions": ["storage"],
  "tools": [{ "name": "echo", "description": "echo", "inputSchema": { "type": "object" } }]
}
"""

private struct StubDownloader: PluginDownloading {
    let payload: Data
    func download(_ url: URL) async throws -> Data { payload }
}

private func makePluginZip(at url: URL) throws {
    let archive = try Archive(url: url, accessMode: .create)
    let files: [(String, Data)] = [
        ("manifest.json", Data(manifestJSON.utf8)),
        ("index.js", Data("globalThis.plugin = { tools: { echo: async () => 'ok' } };".utf8))
    ]
    for (path, data) in files {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<min(start + size, data.count))
        }
    }
}

@Suite("InstallPipeline")
struct InstallPipelineTests {
    private func makeEnvironment() throws -> (root: URL, registry: InstalledRegistry,
                                              payload: Data, key: Curve25519.Signing.PrivateKey,
                                              sha: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marketplace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let zip = root.appendingPathComponent("plugin.zip")
        try makePluginZip(at: zip)
        let payload = try Data(contentsOf: zip)

        let key = Curve25519.Signing.PrivateKey()
        let sha = CryptoService().sha256Hex(payload)
        let registry = InstalledRegistry(fileURL: root.appendingPathComponent("installed.json"))
        return (root, registry, payload, key, sha)
    }

    private func entry(sha: String, key: Curve25519.Signing.PrivateKey) -> RegistryEntry {
        RegistryEntry(
            id: "io.github.alice.echo",
            name: "Echo",
            repo: "alice/echo",
            latestVersion: "1.0.0",
            downloadURL: URL(string: "https://example.com/echo.zip") ?? URL(fileURLWithPath: "/"),
            sha256: sha,
            publicKey: key.publicKey.rawRepresentation.base64EncodedString()
        )
    }

    @Test("installs a verified plugin and records it")
    func happyPath() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let signature = try env.key.signature(for: CryptoService().sha256(env.payload))
        let pipeline = InstallPipeline(
            downloader: StubDownloader(payload: env.payload),
            crypto: CryptoService(),
            registry: env.registry,
            pluginsRoot: env.root.appendingPathComponent("Plugins", isDirectory: true)
        )

        let record = try await pipeline.install(
            entry: entry(sha: env.sha, key: env.key),
            signature: signature,
            approvedPermissions: [.storage]
        )

        #expect(record.id == "io.github.alice.echo")
        #expect(record.version == "1.0.0")
        #expect(record.enabled == false)
        let installed = try await env.registry.plugin(id: record.id)
        #expect(installed?.version == "1.0.0")

        let target = env.root.appendingPathComponent("Plugins/io.github.alice.echo/1.0.0/index.js")
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("rejects a payload whose SHA-256 does not match")
    func checksumMismatch() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let signature = try env.key.signature(for: CryptoService().sha256(env.payload))
        let pipeline = InstallPipeline(
            downloader: StubDownloader(payload: env.payload),
            crypto: CryptoService(),
            registry: env.registry,
            pluginsRoot: env.root.appendingPathComponent("Plugins", isDirectory: true)
        )
        var bad = entry(sha: env.sha, key: env.key)
        bad.sha256 = String(repeating: "0", count: 64)

        await #expect(throws: MarketplaceError.self) {
            _ = try await pipeline.install(entry: bad, signature: signature,
                                           approvedPermissions: [.storage])
        }
        let installed = try await env.registry.all()
        #expect(installed.isEmpty)
    }

    @Test("rejects a signature made by a different key")
    func signatureInvalid() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let otherKey = Curve25519.Signing.PrivateKey()
        let signature = try otherKey.signature(for: CryptoService().sha256(env.payload))
        let pipeline = InstallPipeline(
            downloader: StubDownloader(payload: env.payload),
            crypto: CryptoService(),
            registry: env.registry,
            pluginsRoot: env.root.appendingPathComponent("Plugins", isDirectory: true)
        )

        await #expect(throws: MarketplaceError.self) {
            _ = try await pipeline.install(entry: entry(sha: env.sha, key: env.key),
                                           signature: signature,
                                           approvedPermissions: [.storage])
        }
    }

    @Test("refuses permissions the user did not approve")
    func unapprovedPermission() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let signature = try env.key.signature(for: CryptoService().sha256(env.payload))
        let pipeline = InstallPipeline(
            downloader: StubDownloader(payload: env.payload),
            crypto: CryptoService(),
            registry: env.registry,
            pluginsRoot: env.root.appendingPathComponent("Plugins", isDirectory: true)
        )

        await #expect(throws: MarketplaceError.self) {
            _ = try await pipeline.install(entry: entry(sha: env.sha, key: env.key),
                                           signature: signature,
                                           approvedPermissions: [])
        }
    }
}