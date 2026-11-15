import Foundation
import OSLog

/// Signpost helpers. Each interval is paired with the same name, so Instruments
/// shows one row per operation instead of a soup of begin/end calls.
public struct Signposts: Sendable {
    public enum Name: String, Sendable {
        case llmFirstToken = "llm.first_token"
        case llmStream = "llm.stream"
        case toolExecution = "tool.execution"
        case pluginInstall = "plugin.install"
        case memoryRetrieval = "memory.retrieval"
    }

    private let signposter: OSSignposter

    public init(subsystem: String = "app.amore", category: String = "Performance") {
        self.signposter = OSSignposter(subsystem: subsystem, category: category)
    }

    /// Measures an async operation. Uses `beginInterval`/`endInterval` so the
    /// duration is attributed to the operation, not the caller's stack.
    /// `OSSignposter` only accepts `StaticString`, so the names are mapped back
    /// to literals instead of interpolated strings.
    private static func signpostName(_ name: Name) -> StaticString {
        switch name {
        case .llmFirstToken:   return "llm.first_token"
        case .llmStream:       return "llm.stream"
        case .toolExecution:   return "tool.execution"
        case .pluginInstall:   return "plugin.install"
        case .memoryRetrieval: return "memory.retrieval"
        }
    }

    public func measure<T: Sendable>(
        _ name: Name,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        let key = Self.signpostName(name)
        let state = signposter.beginInterval(key)
        defer { signposter.endInterval(key, state) }
        return try await operation()
    }

    public func event(_ name: Name) {
        signposter.emitEvent(Self.signpostName(name))
    }
}