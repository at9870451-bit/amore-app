import Foundation

// MARK: - Messages

public enum ChatRole: String, Sendable, Codable {
    case system, user, assistant, tool
}

public struct ToolCall: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    /// Raw JSON string exactly as the model produced it (not re-serialised, so
    /// provider-specific quirks survive the round trip).
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct ChatMessage: Sendable, Equatable {
    public var role: ChatRole
    public var content: String
    /// Assistant messages only: the tool calls that accompanied this turn.
    public var toolCalls: [ToolCall]
    /// Tool messages only: which call this result answers.
    public var toolCallID: String?

    public init(role: ChatRole, content: String,
                toolCalls: [ToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: .system, content: text)
    }
    public static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: text)
    }
    public static func assistant(_ text: String, toolCalls: [ToolCall] = []) -> ChatMessage {
        ChatMessage(role: .assistant, content: text, toolCalls: toolCalls)
    }
    public static func tool(_ text: String, callID: String) -> ChatMessage {
        ChatMessage(role: .tool, content: text, toolCallID: callID)
    }
}

// MARK: - Tools

public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    /// JSON Schema as a string; forwarded verbatim to the provider.
    public var inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

// MARK: - Request

public struct ChatRequest: Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    public var systemPrompt: String?
    public var temperature: Double?
    public var maxTokens: Int?

    public init(
        model: String,
        messages: [ChatMessage],
        tools: [ToolSpec] = [],
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

// MARK: - Events

public struct Usage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum FinishReason: String, Sendable, Equatable {
    case stop
    case length
    case toolCalls
    case contentFilter
    case unknown
}

public enum ChatEvent: Sendable, Equatable {
    case textDelta(String)
    /// Streaming tool-call assembly; `index` identifies the call within a turn.
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsFragment: String?)
    case toolCallComplete(ToolCall)
    case usage(Usage)
    case finish(FinishReason)
}