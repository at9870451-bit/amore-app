import Foundation

/// Structural and security checks run before a plugin is ever downloaded. The
/// same validator runs again on the unpacked copy, so a zip that lies about its
/// manifest cannot slip through.
public struct ManifestValidator: Sendable {
    public let hostVersion: String

    public init(hostVersion: String = "1.0.0") {
        self.hostVersion = hostVersion
    }

    public func validate(_ manifest: PluginManifest) throws -> [PluginPermission] {
        guard manifest.schemaVersion == 1 else {
            throw PluginError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard Self.isReverseDomainID(manifest.id) else {
            throw PluginError.invalidPluginID(manifest.id)
        }
        guard Self.isSemver(manifest.version) else {
            throw PluginError.invalidVersion(manifest.version)
        }
        guard Self.isSemver(manifest.minHostVersion) else {
            throw PluginError.invalidVersion(manifest.minHostVersion)
        }
        guard Self.version(hostVersion, isAtLeast: manifest.minHostVersion) else {
            throw PluginError.hostTooOld(required: manifest.minHostVersion, current: hostVersion)
        }
        guard !manifest.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PluginError.malformedManifest("name is empty")
        }

        var seenTools = Set<String>()
        for tool in manifest.tools {
            guard Self.isValidToolName(tool.name) else {
                throw PluginError.invalidToolName(tool.name)
            }
            guard seenTools.insert(tool.name).inserted else {
                throw PluginError.malformedManifest("duplicate tool \(tool.name)")
            }
        }

        switch manifest.type {
        case .js:
            guard let entry = manifest.entry, !entry.isEmpty else {
                throw PluginError.missingEntry("<none>")
            }
            guard entry.hasSuffix(".js"), !entry.contains(".."), !entry.hasPrefix("/") else {
                throw PluginError.malformedManifest("entry must be a relative .js path")
            }
        case .mcp:
            guard manifest.server != nil else {
                throw PluginError.malformedManifest("mcp plugin needs a server block")
            }
        case .prompt:
            guard let templates = manifest.templates, !templates.isEmpty else {
                throw PluginError.malformedManifest("prompt plugin needs at least one template")
            }
        }

        var seenSettings = Set<String>()
        for setting in manifest.settings ?? [] {
            guard seenSettings.insert(setting.key).inserted else {
                throw PluginError.malformedManifest("duplicate setting \(setting.key)")
            }
            if setting.type == .enum, (setting.options ?? []).isEmpty {
                throw PluginError.malformedManifest("enum setting \(setting.key) needs options")
            }
        }

        return try PluginPermissionCatalog.resolve(manifest.permissions)
    }

    // MARK: - Format checks

    static func isReverseDomainID(_ id: String) -> Bool {
        guard id.count <= 128 else { return false }
        let pattern = "^[a-z0-9]+(\\.[a-z0-9][a-z0-9-]*)+$"
        return matches(id, pattern: pattern)
    }

    static func isValidToolName(_ name: String) -> Bool {
        name.count <= 64 && matches(name, pattern: "^[a-z_]{1,64}$")
    }

    static func isSemver(_ value: String) -> Bool {
        matches(value, pattern: "^\\d+\\.\\d+\\.\\d+(-[0-9A-Za-z.-]+)?$")
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }

    /// Numeric comparison on the major.minor.patch triple; pre-release tags are
    /// ignored, which is enough for a host-version gate.
    static func version(_ current: String, isAtLeast required: String) -> Bool {
        let a = current.split(separator: "-").first.map(String.init) ?? current
        let b = required.split(separator: "-").first.map(String.init) ?? required
        let left = a.split(separator: ".").compactMap { Int($0) }
        let right = b.split(separator: ".").compactMap { Int($0) }
        guard left.count >= 1, right.count >= 1 else { return false }
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return true
    }
}