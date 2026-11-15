import CryptoKit
import Foundation

public protocol HTTPCache: Sendable {
    func entry(for key: String) async throws -> HTTPCacheEntry?
    func store(_ entry: HTTPCacheEntry, for key: String) async throws
    func removeAll() async throws
}

/// Writes one JSON file per cache key under Caches/AmoreHTTPCache. A 304 keeps
/// the previous body; a fresh 200 replaces it.
public actor DiskHTTPCache {
    private let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("AmoreHTTPCache", isDirectory: true)
        }
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    public func entry(for key: String) async throws -> HTTPCacheEntry? {
        let url = fileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(HTTPCacheEntry.self, from: data)
        } catch {
            // A corrupt entry must never break a request — drop it and refetch.
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    public func store(_ entry: HTTPCacheEntry, for key: String) async throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entry)
            try data.write(to: fileURL(for: key), options: .atomic)
        } catch {
            throw NetworkError.cache(error.localizedDescription)
        }
    }

    public func removeAll() async throws {
        try? fileManager.removeItem(at: directory)
    }
}

public final class InMemoryHTTPCache: HTTPCache, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: HTTPCacheEntry] = [:]

    public init() {}

    public func entry(for key: String) async throws -> HTTPCacheEntry? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func store(_ entry: HTTPCacheEntry, for key: String) async throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = entry
    }

    public func removeAll() async throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}