import Foundation

/// Long-lived toggles. Defaults are conservative: optional subsystems stay off
/// until the user enables them (cloud sync, marketplace installs).
public enum FeatureFlag: String, CaseIterable, Identifiable, Sendable {
    case pluginMarketplace
    case cloudSync
    case voiceAssistant
    case experimentalAgentLoop

    public var id: String { rawValue }

    public var defaultEnabled: Bool {
        switch self {
        case .pluginMarketplace:      return true
        case .cloudSync:              return false
        case .voiceAssistant:         return true
        case .experimentalAgentLoop:  return false
        }
    }

    public var title: String {
        switch self {
        case .pluginMarketplace:     return "Plugin Marketplace"
        case .cloudSync:             return "iCloud Sync"
        case .voiceAssistant:        return "Voice Assistant"
        case .experimentalAgentLoop: return "Experimental Agent Loop"
        }
    }
}