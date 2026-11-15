import CoreKit
import Foundation
import NetworkKit
import SecurityKit

/// Anthropic Messages API (streaming).
public struct AnthropicProvider: LLMProvider {
    public let id: String
    private let config: ProviderConfig
    private let http: HTTPClient
    private let keychain: KeychainStore

    public init(config: ProviderConfig, http: HTTPClient, keychain: KeychainStore) {
        self.id = config.id
        self.config = config
        self.http = http
        self.keychain = keychain
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = try await keychain.string(for: config.keychainAccount) else {
                        throw LLMError.missingAPIKey(provider: config.displayName)
                    }
                    let body = try AnthropicBodyBuilder.body(for: request, config: config)
                    let endpoint = config.baseURL
                        .appendingPathComponent("v1")
                        .appendingPathComponent("messages")
                    let httpRequest = HTTPRequest(
                        url: endpoint,
                        method: "POST",
                        headers: [
                            "Content-Type": "application/json",
                            "Accept": "text/event-stream",
                            "x-api-key": key,
                            "anthropic-version": "2023-06-01"
                        ],
                        body: body,
                        timeout: 120
                    )

                    var parser = AnthropicStreamParser()
                    for try await event in SSEParser.events(from: http.byteStream(httpRequest)) {
                        if Task.isCancelled { throw LLMError.cancelled }
                        for chatEvent in parser.handle(event) {
                            continuation.yield(chatEvent)
                        }
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

// MARK: - Request body

enum AnthropicBodyBuilder {
    static func body(for request: ChatRequest, config: ProviderConfig) throws -> Data {
        var messages: [[String: Any]] = []
        for message in request.messages {
            switch message.role {
            case .system:
                continue  // Anthropic takes the system prompt out of band
            case .tool:
                messages.append([
                    "role": "user",
                    "content": [[
                        "type": "tool_result",
                        "tool_use_id": message.toolCallID ?? "",
                        "content": message.content
                    ]]
                ])
            case .assistant where !message.toolCalls.isEmpty:
                var blocks: [[String: Any]] = []
                if !message.content.isEmpty {
                    blocks.append(["type": "text", "text": message.content])
                }
                for call in message.toolCalls {
                    let input = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) ?? [:]
                    blocks.append([
                        "type": "tool_use", "id": call.id, "name": call.name, "input": input
                    ])
                }
                messages.append(["role": "assistant", "content": blocks])
            default:
                messages.append(["role": message.role.rawValue, "content": message.content])
            }
        }

        var payload: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens ?? config.defaultMaxTokens,
            "messages": messages,
            "stream": true
        ]
        if let system = request.systemPrompt, !system.isEmpty {
            payload["system"] = system
        }
        if let temperature = request.temperature {
            payload["temperature"] = temperature
        }
        if !request.tools.isEmpty {
            payload["tools"] = request.tools.map { tool in
                let schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8))) ?? [:]
                return [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": schema
                ] as [String: Any]
            }
        }
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw LLMError.invalidConfiguration("request body is not valid JSON")
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

// MARK: - Stream parser

struct AnthropicStreamParser {
    private struct Envelope: Decodable {
        struct Payload: Decodable {
            struct ContentBlock: Decodable {
                let type: String?
                let id: String?
                let name: String?
                let text: String?
            }
            struct Delta: Decodable {
                let type: String?
                let text: String?
                let partial_json: String?
                let stop_reason: String?
            }
            struct UsageDTO: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
            }
            let type: String?
            let index: Int?
            let content_block: ContentBlock?
            let delta: Delta?
            let stop_reason: String?
            let usage: UsageDTO?
        }
        let type: String?
        let index: Int?
        let content_block: Payload.ContentBlock?
        let delta: Payload.Delta?
        let message: MessageStart?
        let usage: Payload.UsageDTO?

        struct MessageStart: Decodable {
            let usage: Payload.UsageDTO?
        }
    }

    private var pending: [Int: (id: String?, name: String?, arguments: String)] = [:]
    private var finished = false

    mutating func handle(_ event: SSEEvent) -> [ChatEvent] {
        guard let data = event.data.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return []
        }
        let type = envelope.type ?? event.event ?? ""

        switch type {
        case "message_start":
            if let usage = envelope.message?.usage {
                return [.usage(Usage(inputTokens: usage.input_tokens,
                                     outputTokens: usage.output_tokens))]
            }
            return []

        case "content_block_start":
            let index = envelope.index ?? 0
            if let block = envelope.content_block, block.type == "tool_use" {
                pending[index] = (block.id, block.name, "")
                return [.toolCallDelta(index: index, id: block.id, name: block.name,
                                       argumentsFragment: nil)]
            }
            if let text = envelope.content_block?.text, !text.isEmpty {
                return [.textDelta(text)]
            }
            return []

        case "content_block_delta":
            let index = envelope.index ?? 0
            guard let delta = envelope.delta else { return [] }
            if delta.type == "text_delta" || delta.text != nil {
                return delta.text.map { [.textDelta($0)] } ?? []
            }
            if delta.type == "input_json_delta", let fragment = delta.partial_json {
                var entry = pending[index] ?? (nil, nil, "")
                entry.arguments += fragment
                pending[index] = entry
                return [.toolCallDelta(index: index, id: nil, name: nil,
                                       argumentsFragment: fragment)]
            }
            return []

        case "content_block_stop":
            let index = envelope.index ?? 0
            guard let entry = pending.removeValue(forKey: index),
                  let id = entry.id, let name = entry.name else { return [] }
            let args = entry.arguments.isEmpty ? "{}" : entry.arguments
            return [.toolCallComplete(ToolCall(id: id, name: name, argumentsJSON: args))]

        case "message_delta":
            var output: [ChatEvent] = []
            if let usage = envelope.usage {
                output.append(.usage(Usage(inputTokens: usage.input_tokens,
                                           outputTokens: usage.output_tokens)))
            }
            if let reason = envelope.delta?.stop_reason {
                output.append(.finish(Self.finishReason(reason)))
                finished = true
            }
            return output

        case "message_stop":
            return finish()

        default:
            return []
        }
    }

    mutating func finish() -> [ChatEvent] {
        guard !finished else { return [] }
        finished = true
        var output: [ChatEvent] = []
        for (_, entry) in pending.sorted(by: { $0.key < $1.key }) {
            guard let id = entry.id, let name = entry.name else { continue }
            let args = entry.arguments.isEmpty ? "{}" : entry.arguments
            output.append(.toolCallComplete(ToolCall(id: id, name: name, argumentsJSON: args)))
        }
        pending.removeAll()
        output.append(.finish(.stop))
        return output
    }

    static func finishReason(_ raw: String) -> FinishReason {
        switch raw {
        case "end_turn", "stop_sequence": return .stop
        case "max_tokens":                return .length
        case "tool_use":                  return .toolCalls
        default:                          return .unknown
        }
    }
}