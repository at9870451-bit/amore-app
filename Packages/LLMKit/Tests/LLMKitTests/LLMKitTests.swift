import Foundation
import Testing

@testable import LLMKit
import NetworkKit

private func decode(_ raw: String) -> [SSEEvent] {
    var decoder = SSEDecoder()
    var events = decoder.feed(Data(raw.utf8))
    events.append(contentsOf: decoder.finish())
    return events
}

@Suite("OpenAI stream")
struct OpenAIStreamTests {
    static let textStream = """
    data: {"choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}

    data: {"choices":[{"delta":{"content":"lo"},"finish_reason":null}]}

    data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

    data: [DONE]


    """

    @Test("text deltas accumulate and finish arrives")
    func textStream() {
        var parser = OpenAIStreamParser()
        var text = ""
        var finishes: [FinishReason] = []
        for event in decode(Self.textStream) {
            for chatEvent in parser.handle(event) {
                switch chatEvent {
                case .textDelta(let delta): text += delta
                case .finish(let reason): finishes.append(reason)
                default: break
                }
            }
        }
        finishes.append(contentsOf: parser.finish().compactMap {
            if case .finish(let r) = $0 { return r } else { return nil }
        })

        #expect(text == "Hello")
        #expect(finishes.contains(.stop))
    }

    static let toolStream = """
    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_weather","arguments":"{\\"ci"}}]},"finish_reason":null}]}

    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ty\\":\\"Paris\\"}"}}]},"finish_reason":null}]}

    data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

    data: [DONE]


    """

    @Test("tool call arguments are assembled from fragments")
    func toolStream() {
        var parser = OpenAIStreamParser()
        var completed: [ToolCall] = []
        var reasons: [FinishReason] = []
        for event in decode(Self.toolStream) {
            for chatEvent in parser.handle(event) {
                switch chatEvent {
                case .toolCallComplete(let call): completed.append(call)
                case .finish(let reason): reasons.append(reason)
                default: break
                }
            }
        }
        #expect(completed.count == 1)
        #expect(completed.first?.id == "call_1")
        #expect(completed.first?.name == "get_weather")
        #expect(completed.first?.argumentsJSON == "{\"city\":\"Paris\"}")
        #expect(reasons.contains(.toolCalls))
    }

    @Test("usage chunk is surfaced")
    func usage() {
        var parser = OpenAIStreamParser()
        let events = decode("""
        data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":4}}

        """)
        var usage: Usage?
        for event in events {
            for chatEvent in parser.handle(event) {
                if case .usage(let value) = chatEvent { usage = value }
            }
        }
        #expect(usage?.inputTokens == 10)
        #expect(usage?.outputTokens == 4)
    }

    @Test("request body carries tools and stream flag")
    func requestBody() throws {
        let config = ProviderConfig(
            id: "test", kind: .openAI, displayName: "Test", model: "gpt-4o-mini",
            baseURL: URL(string: "https://example.com") ?? URL(fileURLWithPath: "/"),
            keychainAccount: "test"
        )
        let request = ChatRequest(
            model: "gpt-4o-mini",
            messages: [.user("weather?")],
            tools: [ToolSpec(name: "get_weather", description: "weather",
                             inputSchemaJSON: #"{"type":"object","properties":{"city":{"type":"string"}}}"#)],
            systemPrompt: "be brief"
        )
        let data = try OpenAIBodyBuilder.body(for: request, config: config)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["stream"] as? Bool == true)
        #expect((json["tools"] as? [[String: Any]])?.count == 1)
        let messages = json["messages"] as? [[String: Any]]
        #expect(messages?.first?["role"] as? String == "system")
    }
}

@Suite("Anthropic stream")
struct AnthropicStreamTests {
    static let textStream = """
    event: message_start
    data: {"type":"message_start","message":{"usage":{"input_tokens":12}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

    event: message_stop
    data: {"type":"message_stop"}


    """

    @Test("text deltas and finish")
    func text() {
        var parser = AnthropicStreamParser()
        var text = ""
        var input: Int?
        var reasons: [FinishReason] = []
        for event in decode(Self.textStream) {
            for chatEvent in parser.handle(event) {
                switch chatEvent {
                case .textDelta(let delta): text += delta
                case .usage(let usage): if let value = usage.inputTokens { input = value }
                case .finish(let reason): reasons.append(reason)
                default: break
                }
            }
        }
        #expect(text == "Hi there")
        #expect(input == 12)
        #expect(reasons.contains(.stop))
    }

    static let toolStream = """
    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_weather"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\\"Paris\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}


    """

    @Test("tool_use blocks assemble into one ToolCall")
    func toolUse() {
        var parser = AnthropicStreamParser()
        var completed: [ToolCall] = []
        var reasons: [FinishReason] = []
        for event in decode(Self.toolStream) {
            for chatEvent in parser.handle(event) {
                switch chatEvent {
                case .toolCallComplete(let call): completed.append(call)
                case .finish(let reason): reasons.append(reason)
                default: break
                }
            }
        }
        #expect(completed.count == 1)
        #expect(completed.first?.id == "toolu_1")
        #expect(completed.first?.name == "get_weather")
        #expect(completed.first?.argumentsJSON == "{\"city\":\"Paris\"}")
        #expect(reasons.contains(.toolCalls))
    }

    @Test("system prompt is lifted out of the message list")
    func systemPrompt() throws {
        let config = ProviderConfig(
            id: "a", kind: .anthropic, displayName: "Anthropic", model: "claude",
            baseURL: URL(string: "https://example.com") ?? URL(fileURLWithPath: "/"),
            keychainAccount: "anthropic"
        )
        let request = ChatRequest(model: "claude",
                                  messages: [.user("hi")],
                                  systemPrompt: "be nice")
        let data = try AnthropicBodyBuilder.body(for: request, config: config)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["system"] as? String == "be nice")
        #expect(json["stream"] as? Bool == true)
        let messages = json["messages"] as? [[String: Any]]
        #expect(messages?.count == 1)
        #expect(messages?.first?["role"] as? String == "user")
    }
}