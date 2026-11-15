import Foundation
import ZIPFoundation

/// Hard limits applied before anything is written to disk. A plugin is a
/// download from the internet, so the archive is treated as hostile.
public struct PluginArchiveLimits: Sendable {
    public var maxUncompressedBytes: Int
    public var maxEntries: Int

    public init(maxUncompressedBytes: Int = 10 * 1024 * 1024, maxEntries: Int = 500) {
        self.maxUncompressedBytes = maxUncompressedBytes
        self.maxEntries = maxEntries
    }
}

public enum PluginArchive {
    /// Extracts a plugin zip into `destination`, rejecting traversal, symlinks
    /// and oversize payloads. Returns the validated manifest that was found
    /// inside the package.
    @discardableResult
    public static func unpack(
        zipAt zipURL: URL,
        to destination: URL,
        limits: PluginArchiveLimits = PluginArchiveLimits(),
        hostVersion: String = "1.0.0"
    ) throws -> (manifest: PluginManifest, permissions: [PluginPermission]) {
        guard let archive = Archive(url: zipURL, accessMode: .read) else {
            throw PluginError.runtime("cannot open archive")
        }

        var totalBytes = 0
        var count = 0
        let root = destination.standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for entry in archive {
            count += 1
            guard count <= limits.maxEntries else {
                throw PluginError.runtime("archive has more than \(limits.maxEntries) entries")
            }

            guard let target = safeDestination(for: entry.path, root: root) else {
                throw PluginError.runtime("unsafe path in archive: \(entry.path)")
            }

            switch entry.type {
            case .symlink:
                throw PluginError.runtime("symlinks are not allowed in plugins")
            case .directory:
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            case .file:
                break
            }

            totalBytes += Int(entry.uncompressedSize)
            guard totalBytes <= limits.maxUncompressedBytes else {
                throw PluginError.runtime("archive expands beyond \(limits.maxUncompressedBytes) bytes")
            }

            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: target)
        }

        let manifestURL = root.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PluginError.malformedManifest("manifest.json is missing")
        }
        let manifest = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(contentsOf: manifestURL))
        let permissions = try ManifestValidator(hostVersion: hostVersion).validate(manifest)

        if manifest.type == .js, let entry = manifest.entry {
            let entryURL = root.appendingPathComponent(entry)
            let entryPath = entryURL.standardizedFileURL.path
            guard entryPath.hasPrefix(root.path + "/"),
                  FileManager.default.fileExists(atPath: entryPath) else {
                throw PluginError.missingEntry(entry)
            }
        }

        return (manifest, permissions)
    }

    /// Rejects absolute paths, Windows drive letters, backslashes and any `..`
    /// component; then confirms the resolved path is inside `root`.
    static func safeDestination(for path: String, root: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            return nil
        }
        if path.count >= 2, path[path.index(path.startIndex, offsetBy: 1)] == ":" {
            return nil
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains("..") else { return nil }

        let target = root.appendingPathComponent(path).standardizedFileURL
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else { return nil }
        return target
    }
}