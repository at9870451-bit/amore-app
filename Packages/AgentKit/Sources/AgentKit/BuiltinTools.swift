import CoreKit
import Foundation
import LLMKit

/// Storage the memory tools talk to. Implemented by MemoryKit in P4; the agent
/// only depends on these narrow protocols.
public protocol MemorySearching: Sendable {
    func search(_ query: String, limit: Int) async throws -> [String]
}

public protocol MemoryWriting: Sendable {
    func save(_ content: String) async throws
}

public struct CurrentTimeTool: AgentTool {
    public let name = "current_time"
    public let description = "Returns the current date and time in ISO 8601."
    public let inputSchemaJSON = #"{"type":"object","properties":{}}"#

    private let clock: any AmoreClock

    public init(clock: any AmoreClock = SystemClock()) {
        self.clock = clock
    }

    public func execute(argumentsJSON: String) async throws -> String {
        ISO8601DateFormatter().string(from: clock.now)
    }
}

public struct MemorySearchTool: AgentTool {
    public let name = "memory_search"
    public let description = "Search the user's long-term memory for relevant facts."
    public let inputSchemaJSON = #"""
    {"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":10}},"required":["query"]}
    """#

    private let store: any MemorySearching

    public init(store: any MemorySearching) {
        self.store = store
    }

    private struct Arguments: Decodable {
        let query: String
        let limit: Int?
    }

    public func execute(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(Arguments.self, from: data) else {
            throw AgentError.toolFailed(name: name, message: "query is required")
        }
        let results = try await store.search(arguments.query,
                                            limit: min(max(arguments.limit ?? 5, 1), 10))
        if results.isEmpty { return "No matching memories." }
        return results.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}

public struct MemorySaveTool: AgentTool {
    public let name = "memory_save"
    public let description = "Save a durable fact about the user for future conversations."
    public let inputSchemaJSON = #"""
    {"type":"object","properties":{"content":{"type":"string"}},"required":["content"]}
    """#

    private let store: any MemoryWriting

    public init(store: any MemoryWriting) {
        self.store = store
    }

    private struct Arguments: Decodable {
        let content: String
    }

    public func execute(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(Arguments.self, from: data),
              !arguments.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.toolFailed(name: name, message: "content is required")
        }
        try await store.save(arguments.content)
        return "Saved."
    }
}

/// Convenience set for a fresh install.
public enum BuiltinTools {
    public static func make(
        clock: any AmoreClock = SystemClock(),
        memory: (any MemorySearching & MemoryWriting)? = nil
    ) -> [any AgentTool] {
        var tools: [any AgentTool] = [CurrentTimeTool(clock: clock)]
        if let memory {
            tools.append(MemorySearchTool(store: memory))
            tools.append(MemorySaveTool(store: memory))
        }
        return tools
    }
}