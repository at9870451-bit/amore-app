import Foundation

/// Permissions a plugin may request. Anything not matching these forms is
/// rejected at install time — the app never grants a capability it cannot name.
public enum PluginPermission: Sendable, Equatable, Hashable {
    case storage
    case secrets
    case notify
    case network(host: String)

    /// Canonical string form used in manifests.
    public var rawValue: String {
        switch self {
        case .storage: return "storage"
        case .secrets: return "secrets"
        case .notify:  return "notify"
        case .network(let host): return "network:\(host)"
        }
    }

    public static let fixed: Set<String> = ["storage", "secrets", "notify"]

    /// Parses one manifest string.
    public static func parse(_ value: String) -> PluginPermission? {
        if fixed.contains(value) {
            switch value {
            case "storage": return .storage
            case "secrets": return .secrets
            case "notify":  return .notify
            default:        return nil
            }
        }
        if value.hasPrefix("network:") {
            let host = String(value.dropFirst("network:".count)).lowercased()
            guard isValidHost(host) else { return nil }
            return .network(host: host)
        }
        return nil
    }

    /// Hosts must be bare domains — no scheme, path, port or wildcard.
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        if host.contains("/") || host.contains(":") || host.contains("*") || host.contains(" ") {
            return false
        }
        let pattern = "^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(host.startIndex..<host.endIndex, in: host)
        return regex.firstMatch(in: host, options: [], range: range) != nil
    }

    /// Chinese explanation shown on the consent sheet (spec: 逐条用中文解释).
    public var localizedExplanation: String {
        switch self {
        case .storage:
            return "保存插件自己的数据（最多 1 MB，按插件隔离）"
        case .secrets:
            return "读取你在设置里为这个插件填写的密钥"
        case .notify:
            return "发送通知"
        case .network(let host):
            return "通过 HTTPS 访问 \(host)"
        }
    }
}

public enum PluginPermissionCatalog {
    /// Turns manifest strings into typed permissions, rejecting unknown ones.
    public static func resolve(_ raw: [String]) throws -> [PluginPermission] {
        var result: [PluginPermission] = []
        for value in raw {
            guard let permission = PluginPermission.parse(value) else {
                throw PluginError.unknownPermission(value)
            }
            if !result.contains(permission) { result.append(permission) }
        }
        return result
    }

    /// Hosts a plugin declared for `network:` — used by the JS fetch gate.
    public static func allowedHosts(_ permissions: [PluginPermission]) -> Set<String> {
        Set(permissions.compactMap {
            if case .network(let host) = $0 { return host }
            return nil
        })
    }

    public static func has(_ permission: PluginPermission, in list: [PluginPermission]) -> Bool {
        list.contains(permission)
    }
}