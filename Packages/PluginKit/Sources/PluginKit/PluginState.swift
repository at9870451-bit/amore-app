import Foundation

/// Lifecycle of an installed plugin. Transitions are validated so a stale
/// install can never resurrect an uninstalled plugin.
public enum PluginState: String, Sendable, Equatable, Codable {
    case notInstalled
    case downloading
    case verifying
    case installedDisabled = "installed(disabled)"
    case enabled
    case updating
    case failed

    public var isRunnable: Bool { self == .enabled }

    /// Legal destinations from this state.
    public var allowedNext: Set<PluginState> {
        switch self {
        case .notInstalled:       return [.downloading, .failed]
        case .downloading:        return [.verifying, .failed, .notInstalled]
        case .verifying:          return [.installedDisabled, .failed]
        case .installedDisabled:  return [.enabled, .updating, .notInstalled, .failed]
        case .enabled:            return [.installedDisabled, .updating, .notInstalled, .failed]
        case .updating:           return [.installedDisabled, .enabled, .failed]
        case .failed:             return [.notInstalled, .downloading, .installedDisabled]
        }
    }
}

public struct PluginStateMachine: Sendable {
    public private(set) var state: PluginState

    public init(state: PluginState = .notInstalled) {
        self.state = state
    }

    public mutating func transition(to next: PluginState) throws {
        guard state.allowedNext.contains(next) else {
            throw PluginError.illegalTransition(from: state, to: next)
        }
        state = next
    }
}
