import Foundation
import LLMKit

public enum ToolPermission: Sendable, Equatable {
    case alwaysAllow
    case askEachTime
    case deny
}

public enum PermissionDecision: Sendable, Equatable {
    case allowed
    case denied(reason: String)
    case needsConfirmation
}

/// Who answers "may this tool run?". The UI supplies a prompter that shows a
/// sheet; tests supply scripted answers.
public protocol PermissionPrompter: Sendable {
    func confirm(tool: String, argumentsJSON: String) async -> Bool
}

public struct AlwaysAllowPrompter: PermissionPrompter {
    public init() {}
    public func confirm(tool: String, argumentsJSON: String) async -> Bool { true }
}

public struct AlwaysDenyPrompter: PermissionPrompter {
    public init() {}
    public func confirm(tool: String, argumentsJSON: String) async -> Bool { false }
}

/// Central policy gate. Policies live in memory for now; P4 will persist them.
public actor PermissionGateway {
    private var policies: [String: ToolPermission]
    private let prompter: any PermissionPrompter

    public init(policies: [String: ToolPermission] = [:],
                prompter: any PermissionPrompter = AlwaysDenyPrompter()) {
        self.policies = policies
        self.prompter = prompter
    }

    public func setPolicy(_ policy: ToolPermission, for tool: String) {
        policies[tool] = policy
    }

    public func policy(for tool: String) -> ToolPermission {
        policies[tool] ?? .askEachTime
    }

    /// Resolves once: alwaysAllow returns immediately, askEachTime consults the
    /// prompter, deny never runs.
    public func authorize(tool: String, argumentsJSON: String) async -> PermissionDecision {
        switch policy(for: tool) {
        case .alwaysAllow:
            return .allowed
        case .deny:
            return .denied(reason: "Blocked by your tool settings.")
        case .askEachTime:
            let approved = await prompter.confirm(tool: tool, argumentsJSON: argumentsJSON)
            return approved ? .allowed : .denied(reason: "You declined this tool call.")
        }
    }
}

/// Runtime registry: plugins register their tools when enabled and unregister
/// when disabled, so the agent's tool list tracks the installed set.
public actor ToolRegistry {
    private var tools: [String: any AgentTool] = [:]

    public init(initial: [any AgentTool] = []) {
        for tool in initial { tools[tool.name] = tool }
    }

    public func register(_ tool: any AgentTool) throws {
        guard !tool.name.isEmpty else { throw AgentError.toolNotFound("<empty>") }
        tools[tool.name] = tool
    }

    public func register(_ list: [any AgentTool]) {
        for tool in list { tools[tool.name] = tool }
    }

    public func unregister(_ name: String) {
        tools.removeValue(forKey: name)
    }

    public func unregisterAll(prefix: String) {
        for name in tools.keys where name.hasPrefix(prefix) {
            tools.removeValue(forKey: name)
        }
    }

    public func tool(named name: String) -> (any AgentTool)? {
        tools[name]
    }

    public func specs() -> [ToolSpec] {
        tools.values.map(\.spec).sorted { $0.name < $1.name }
    }

    public func names() -> [String] {
        tools.keys.sorted()
    }
}