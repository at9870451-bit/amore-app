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
    public func measure<T: Sendable>(
        _ name: Name,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        let state = signposter.beginInterval(name.rawValue)
        defer { signposter.endInterval(name.rawValue, state) }
        return try await operation()
    }

    public func event(_ name: Name, detail: String = "") {
        if detail.isEmpty {
            signposter.emitEvent(name.rawValue)
        } else {
            signposter.emitEvent("\(name.rawValue).\(detail)")
        }
    }
}