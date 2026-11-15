import Foundation

/// Parses `amore://` URLs into routes.
///
/// Supported forms:
/// - `amore://plugin/install?id=io.github.alice.weather`
/// - `amore://plugin/detail?id=io.github.alice.weather`
/// - `amore://marketplace`
/// - `amore://chat?session=abc`
/// - `amore://settings`
public enum DeepLink {
    public static let scheme = "amore"

    public static func route(from url: URL) -> Route? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let host = components.host?.lowercased() ?? ""
        let path = components.path.lowercased()
        let items = components.queryItems ?? []

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        switch (host, path) {
        case ("plugin", "/install"):
            guard let id = value("id"), isValidPluginID(id) else { return nil }
            return .pluginInstall(id: id)

        case ("plugin", "/detail"):
            guard let id = value("id"), isValidPluginID(id) else { return nil }
            return .pluginDetail(id: id)

        case ("marketplace", _):
            return .marketplace

        case ("chat", _):
            return .chat(sessionID: value("session"))

        case ("settings", _):
            return .settings

        default:
            return nil
        }
    }

    /// Plugins are addressed by reverse-domain ids; reject anything else before
    /// it reaches the installer.
    static func isValidPluginID(_ id: String) -> Bool {
        let pattern = "^[a-z0-9]+(\\.[a-z0-9][a-z0-9-]*)+$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(id.startIndex..<id.endIndex, in: id)
        return regex.firstMatch(in: id, options: [], range: range) != nil
            && id.count <= 128
    }
}