import Foundation

public enum PluginError: LocalizedError, Sendable, Equatable {
    case malformedManifest(String)
    case unsupportedSchemaVersion(Int)
    case invalidPluginID(String)
    case invalidVersion(String)
    case invalidToolName(String)
    case unknownPermission(String)
    case hostTooOld(required: String, current: String)
    case missingEntry(String)
    case illegalTransition(from: PluginState, to: PluginState)
    case runtime(String)
    case permissionDenied(String)
    case timeout(tool: String, seconds: Int)
    case disabledAfterTimeouts(tool: String)
    case storageQuotaExceeded(limitBytes: Int)
    case responseTooLarge(limitBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .malformedManifest(let detail):   return "Plugin manifest is invalid. \(detail)"
        case .unsupportedSchemaVersion(let v): return "Manifest schemaVersion \(v) is not supported."
        case .invalidPluginID(let id):
            return "Plugin id “\(id)” is not a reverse-domain identifier."
        case .invalidVersion(let v):           return "“\(v)” is not a semantic version."
        case .invalidToolName(let name):
            return "Tool name “\(name)” must match ^[a-z_]{1,64}$."
        case .unknownPermission(let p):        return "Permission “\(p)” is not in the allowlist."
        case .hostTooOld(let required, let current):
            return "This plugin needs Amore \(required) or newer (you have \(current))."
        case .missingEntry(let entry):         return "Entry file “\(entry)” is missing from the package."
        case .illegalTransition(let from, let to):
            return "Cannot go from \(from.rawValue) to \(to.rawValue)."
        case .runtime(let detail):             return "Plugin runtime error. \(detail)"
        case .permissionDenied(let p):         return "The plugin is missing the “\(p)” permission."
        case .timeout(let tool, let seconds):
            return "“\(tool)” did not finish within \(seconds) seconds."
        case .disabledAfterTimeouts(let tool):
            return "“\(tool)” timed out three times; the plugin was disabled."
        case .storageQuotaExceeded(let limit):
            return "Plugin storage exceeded \(limit) bytes."
        case .responseTooLarge(let limit):
            return "Response exceeded the \(limit)-byte limit."
        }
    }
}