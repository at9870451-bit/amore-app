import CoreKit
import CryptoKit
import Foundation
import NetworkKit
import PluginKit
import SecurityKit

public struct InstalledPlugin: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var version: String
    public var previousVersion: String?
    public var enabled: Bool
    public var installedAt: Date
    public var permissions: [String]

    public init(id: String, version: String, previousVersion: String? = nil,
                enabled: Bool = false, installedAt: Date = Date(),
                permissions: [String] = []) {
        self.id = id
        self.version = version
        self.previousVersion = previousVersion
        self.enabled = enabled
        self.installedAt = installedAt
        self.permissions = permissions
    }
}

/// `installed.json`: the single source of truth for what is on disk.
public actor InstalledRegistry {
    private let fileURL: URL
    private let fileManager = FileManager.default

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func all() throws -> [InstalledPlugin] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try JSONDecoder().decode([InstalledPlugin].self,
                                            from: Data(contentsOf: fileURL))
        } catch {
            throw MarketplaceError.installFailed("installed.json is corrupt")
        }
    }

    public func plugin(id: String) throws -> InstalledPlugin? {
        try all().first { $0.id == id }
    }

    public func record(_ plugin: InstalledPlugin) throws {
        var list = try all()
        if let index = list.firstIndex(where: { $0.id == plugin.id }) {
            list[index] = plugin
        } else {
            list.append(plugin)
        }
        try write(list)
    }

    public func setEnabled(id: String, enabled: Bool) throws {
        var list = try all()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].enabled = enabled
        try write(list)
    }

    public func remove(id: String) throws {
        var list = try all()
        list.removeAll { $0.id == id }
        try write(list)
    }

    /// Drops the newest version and points back at the previous one.
    public func markRolledBack(id: String) throws {
        var list = try all()
        guard let index = list.firstIndex(where: { $0.id == id }),
              let previous = list[index].previousVersion else { return }
        list[index].version = previous
        list[index].previousVersion = nil
        list[index].enabled = false
        try write(list)
    }

    private func write(_ list: [InstalledPlugin]) throws {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(list)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw MarketplaceError.installFailed(error.localizedDescription)
        }
    }
}

// MARK: - Downloading

public protocol PluginDownloading: Sendable {
    func download(_ url: URL) async throws -> Data
}

public struct HTTPPluginDownloader: PluginDownloading {
    private let http: HTTPClient
    private let maxBytes: Int

    public init(http: HTTPClient, maxBytes: Int = 10 * 1024 * 1024) {
        self.http = http
        self.maxBytes = maxBytes
    }

    public func download(_ url: URL) async throws -> Data {
        var collected = Data()
        for try await chunk in http.byteStream(HTTPRequest(url: url)) {
            collected.append(chunk)
            if collected.count > maxBytes {
                throw PluginError.responseTooLarge(limitBytes: maxBytes)
            }
        }
        return collected
    }
}

// MARK: - Pipeline

/// Installs one registry entry. Every step is cancellable; any failure removes
/// the partial download so a half-extracted plugin never stays on disk.
public actor InstallPipeline {
    private let downloader: any PluginDownloading
    private let crypto: CryptoService
    private let registry: InstalledRegistry
    private let pluginsRoot: URL
    private let hostVersion: String
    private let fileManager = FileManager.default

    public init(downloader: any PluginDownloading, crypto: CryptoService,
                registry: InstalledRegistry, pluginsRoot: URL,
                hostVersion: String = "1.0.0") {
        self.downloader = downloader
        self.crypto = crypto
        self.registry = registry
        self.pluginsRoot = pluginsRoot
        self.hostVersion = hostVersion
    }

    public func install(
        entry: RegistryEntry,
        signature: Data,
        approvedPermissions: [PluginPermission]
    ) async throws -> InstalledPlugin {
        let work = pluginsRoot.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        do {
            if Task.isCancelled { throw PluginError.runtime("cancelled") }

            let payload = try await downloader.download(entry.downloadURL)
            let actualSHA = crypto.sha256Hex(payload)
            guard actualSHA.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
                throw MarketplaceError.checksumMismatch(expected: entry.sha256, actual: actualSHA)
            }

            let digest = crypto.sha256(payload)
            let verified = try crypto.verifyEd25519(signature: signature, data: digest,
                                                    publicKey: try publicKey(from: entry.publicKey))
            guard verified else { throw MarketplaceError.signatureInvalid }

            let zipURL = work.appendingPathComponent("plugin.zip")
            try payload.write(to: zipURL, options: .atomic)

            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            let result = try PluginArchive.unpack(zipAt: zipURL, to: unpacked,
                                                  hostVersion: hostVersion)
            guard result.manifest.id == entry.id else {
                throw MarketplaceError.installFailed("manifest id does not match the registry entry")
            }
            guard result.manifest.version == entry.latestVersion else {
                throw MarketplaceError.installFailed("manifest version does not match the registry entry")
            }
            guard Set(result.permissions).isSubset(of: Set(approvedPermissions)) else {
                throw MarketplaceError.installFailed("plugin requests permissions that were not approved")
            }

            let target = pluginsRoot
                .appendingPathComponent(entry.id, isDirectory: true)
                .appendingPathComponent(entry.latestVersion, isDirectory: true)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: unpacked, to: target)

            let previous = try await registry.plugin(id: entry.id)?.version
            let record = InstalledPlugin(
                id: entry.id,
                version: entry.latestVersion,
                previousVersion: previous == entry.latestVersion ? nil : previous,
                enabled: false,
                permissions: result.permissions.map(\.rawValue)
            )
            try await registry.record(record)
            return record
        } catch {
            throw error
        }
    }

    /// Restores the previous version directory; if it is gone the plugin is
    /// uninstalled rather than left pointing at code that failed to load.
    public func rollback(id: String) async throws -> InstalledPlugin? {
        guard let current = try await registry.plugin(id: id),
              let previous = current.previousVersion else { return nil }
        let currentDir = pluginsRoot.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(current.version, isDirectory: true)
        let previousDir = currentDir.deletingLastPathComponent()
            .appendingPathComponent(previous, isDirectory: true)

        guard fileManager.fileExists(atPath: previousDir.path) else {
            if fileManager.fileExists(atPath: currentDir.path) {
                try? fileManager.removeItem(at: currentDir)
            }
            try await registry.remove(id: id)
            return nil
        }
        if fileManager.fileExists(atPath: currentDir.path) {
            try fileManager.removeItem(at: currentDir)
        }
        try await registry.markRolledBack(id: id)
        return try await registry.plugin(id: id)
    }

    public func uninstall(id: String) async throws {
        let dir = pluginsRoot.appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
        try await registry.remove(id: id)
    }

    private func publicKey(from base64: String) throws -> Data {
        guard let data = Data(base64Encoded: base64), data.count == 32 else {
            throw PluginError.malformedManifest("publicKey is not a 32-byte base64 value")
        }
        return data
    }
}