import Foundation
import LLMKit

public enum AgentError: LocalizedError, Sendable, Equatable {
    case maxRoundsExceeded(Int)
    case toolNotFound(String)
    case toolTimeout(name: String, seconds: Int)
    case toolFailed(name: String, message: String)
    case provider(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .maxRoundsExceeded(let limit):
            return "The agent stopped after \(limit) rounds without finishing."
        case .toolNotFound(let name):
            return "No tool named \(name) is registered."
        case .toolTimeout(let name, let seconds):
            return "\(name) did not finish within \(seconds) seconds."
        case .toolFailed(let name, let message):
            return "\(name) failed. \(message)"
        case .provider(let message):
            return "The model returned an error. \(message)"
        case .cancelled:
            return "The run was cancelled."
        }
    }
}

/// Everything the UI needs, in order. Every event is Sendable so it can cross
/// from the agent actor back to the main-actor store.
public enum AgentEvent: Sendable, Equatable {
    case started
    case textDelta(String)
    case toolCallStarted(ToolCall)
    case toolCallFinished(ToolCall, output: String, durationMilliseconds: Int)
    case toolCallRejected(ToolCall, reason: String)
    case roundFinished(Int)
    case usage(Usage)
    case finished(FinishReason)
}

/// A capability the agent may call. Arguments arrive as the raw JSON string
/// produced by the model; tools parse it themselves so provider quirks survive.
public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchemaJSON: String { get }
    func execute(argumentsJSON: String) async throws -> String
}

public extension AgentTool {
    var spec: ToolSpec {
        ToolSpec(name: name, description: description, inputSchemaJSON: inputSchemaJSON)
    }
}