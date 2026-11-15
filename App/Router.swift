import Foundation
import Observation
import SwiftUI

/// Root destinations. Everything that can be pushed lives here so features
/// never import each other — they only speak `Route`.
public enum AppTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case chat, agents, tasks, memory, profile

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chat:    return "Chat"
        case .agents:  return "Agents"
        case .tasks:   return "Tasks"
        case .memory:  return "Memory"
        case .profile: return "Profile"
        }
    }

    public var symbol: String {
        switch self {
        case .chat:    return "bubble.left.and.bubble.right.fill"
        case .agents:  return "person.2.wave.2.fill"
        case .tasks:   return "checklist"
        case .memory:  return "brain.head.profile"
        case .profile: return "person.crop.circle"
        }
    }
}

/// Hashable route values pushed onto a tab's navigation stack.
public enum Route: Hashable, Sendable {
    case chat(sessionID: String?)
    case agents
    case tasks
    case memory
    case profile
    case marketplace
    case pluginDetail(id: String)
    case pluginInstall(id: String)
    case settings
}

/// Navigation state for the whole app. One stack per tab, plus a selection for
/// the split layout's sidebar.
@MainActor
@Observable
public final class Router {
    public var selectedTab: AppTab = .chat
    public private(set) var stacks: [AppTab: [Route]] = [:]
    public var selectedRoute: Route?

    public init() {}

    public func path(for tab: AppTab) -> [Route] {
        stacks[tab] ?? []
    }

    public func setPath(_ routes: [Route], for tab: AppTab) {
        stacks[tab] = routes
    }

    public func push(_ route: Route, on tab: AppTab? = nil) {
        let target = tab ?? selectedTab
        var routes = stacks[target] ?? []
        routes.append(route)
        stacks[target] = routes
        selectedTab = target
    }

    public func pop(_ tab: AppTab? = nil) {
        let target = tab ?? selectedTab
        guard var routes = stacks[target], !routes.isEmpty else { return }
        routes.removeLast()
        stacks[target] = routes
    }

    public func reset(_ tab: AppTab? = nil) {
        let target = tab ?? selectedTab
        stacks[target] = []
    }

    /// Entry point for `amore://` URLs. Returns false when the URL is unknown so
    /// the caller can fall back (e.g. open in Safari).
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        guard let route = DeepLink.route(from: url) else { return false }
        push(route)
        return true
    }
}