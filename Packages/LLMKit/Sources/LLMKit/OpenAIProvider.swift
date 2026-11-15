import CoreKit
import Foundation
import NetworkKit

/// OpenAI Chat Completions. Also the base for OpenAI-compatible endpoints
/// (Ollama, LM Studio, OpenRouter…), which only differ in base URL.
public struct OpenAIProvider: LLMProvider {
    public let id: String
    private let config: ProviderConfig
    private let http: HTTPClient
    private let keychain: KeychainStore
    private let isCompatible: Bool

    public init(config: ProviderConfig, http: HTTPClient, keychain: KeychainStore,
                compatible: Bool = false) {
        self.id = config.id
        self.config = config
        self.http = http
        self.keychain = keychain
        self.isCompatible = compatible
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let key = try await keychain.string(for: config.keychainAccount)
                    if key == nil && !isCompatible {
                        throw LLMError.missingAPIKey(provider: config.displayName)
                    }
                    let body = try OpenAIBodyBuilder.body(for: request, config: config)
                    var headers: [String: String] = [
                        "Content-Type": "application/json",
                        "Accept": "text/event-stream"
                    ]
                    if let key { headers["Authorization"] = "Bearer \(key)" }

                    let endpoint = config.baseURL
                        .appendingPathComponent("v1")
                        .appendingPathComponent("chat/completions")
                    let httpRequest = HTTPRequest(
                        url: endpoint,
                        method: "POST",
                        headers: headers,
                        body: body,
                        timeout: 120,
                        useETag: false
                    )

                    var parser = OpenAIStreamParser()
                    let chunks = SSEParser.events(from: http.byteStream(httpRequest))
                    for try await event in chunks {
                        if Task.isCancelled { throw LLMError.cancelled }
                        for chatEvent in parser.handle(event) {
                            continuation.yield(chatEvent)
                        }
                        if event.data == "[DONE]" { break }
                    }
                    for chatEvent in parser.finish() {
                        continuation.yield(chatEvent)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// OpenAI-compatible endpoint (Ollama, OpenRouter, LM Studio…). Same wire
/// format, arbitrary base URL, optional key.
public struct OpenAICompatibleProvider: LLMProvider {
    public let id: String
    private let base: OpenAIProvider

    public init(config: ProviderConfig, http: HTTPClient, keychain: KeychainStore) {
        self.id = config.id
        self.base = OpenAIProvider(config: config, http: http, keychain: keychain, compatible: true)
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        base.stream(request)
    }
}

// MARK: - Request body

enum OpenAIBodyBuilder {
    static func body(for request: ChatRequest, config: ProviderConfig) throws -> Data {
        var messages: [[String: Any]] = []
        if let system = request.systemPrompt, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        for message in request.messages {
            switch message.role {
            case .assistant where !message.toolCalls.isEmpty:
                messages.append([
                    "role": "assistant",
                    "content": message.content,
                    "tool_calls": message.toolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": ["name": call.name, "arguments": call.argumentsJSON]
                        ]
                    }
                ])
            case .tool:
                messages.append([
                    "role": "tool",
                    "tool_call_id": message.toolCallID ?? "",
                    "content": message.content
                ])
            default:
                messages.append(["role": message.role.rawValue, "content": message.content])
            }
        }

        var payload: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": request.maxTokens ?? config.defaultMaxTokens
        ]
        if let temperature = request.temperature { payload["temperature"] = temperature }
        if !request.tools.isEmpty {
            payload["tools"] = request.tools.map { tool in
                let schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8))) ?? [:]
                return [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": schema
                    ] as [String: Any]
                ]
            }
        }
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw LLMError.invalidConfiguration("request body is not valid JSON")
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

// MARK: - Stream parser

/// Pure parser (no I/O) so recorded streams can be tested directly.
struct OpenAIStreamParser {
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct Call: Decodable {
                    struct Function: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let index: Int?
                    let id: String?
                    let function: Function?
                }
                let content: String?
                let tool_calls: [Call]?
            }
            let delta: Delta?
            let finish_reason: String?
        }
        struct UsageDTO: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
        }
        let choices: [Choice]?
        let usage: UsageDTO?
    }

    private var pending: [Int: (id: String?, name: String?, arguments: String)] = [:]
    private var finished = false

    mutating func handle(_ event: SSEEvent) -> [ChatEvent] {
        if event.data == "[DONE]" { return finish() }
        guard let data = event.data.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else {
            return []
        }

        var output: [ChatEvent] = []
        if let usage = chunk.usage {
            output.append(.usage(Usage(inputTokens: usage.prompt_tokens,
                                       outputTokens: usage.completion_tokens)))
        }
        for choice in chunk.choices ?? [] {
            if let text = choice.delta?.content, !text.isEmpty {
                output.append(.textDelta(text))
            }
            for call in choice.delta?.tool_calls ?? [] {
                let index = call.index ?? 0
                var entry = pending[index] ?? (nil, nil, "")
                if let id = call.id, !id.isEmpty { entry.id = id }
                if let name = call.function?.name, !name.isEmpty { entry.name = name }
                if let fragment = call.function?.arguments { entry.arguments += fragment }
                pending[index] = entry
                output.append(.toolCallDelta(index: index, id: call.id,
                                             name: call.function?.name,
                                             argumentsFragment: call.function?.arguments))
            }
            if let reason = choice.finish_reason {
                output.append(contentsOf: completePendingToolCalls())
                output.append(.finish(Self.finishReason(reason)))
            }
        }
        return output
    }

    mutating func finish() -> [ChatEvent] {
        guard !finished else { return [] }
        finished = true
        var output = completePendingToolCalls()
        if !output.contains(where: { if case .finish = $0 { return true } else { return false } }) {
            output.append(.finish(.stop))
        }
        return output
    }

    private mutating func completePendingToolCalls() -> [ChatEvent] {
        guard !pending.isEmpty else { return [] }
        let calls = pending.sorted { $0.key < $1.key }.compactMap { _, value -> ChatEvent? in
            guard let id = value.id, let name = value.name else { return nil }
            let args = value.arguments.isEmpty ? "{}" : value.arguments
            return .toolCallComplete(ToolCall(id: id, name: name, argumentsJSON: args))
        }
        pending.removeAll()
        return calls
    }

    static func finishReason(_ raw: String) -> FinishReason {
        switch raw {
        case "stop":          return .stop
        case "length":        return .length
        case "tool_calls", "function_call": return .toolCalls
        case "content_filter": return .contentFilter
        default:              return .unknown
        }
    }
}