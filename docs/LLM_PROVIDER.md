# LLM Provider 契约

## 协议

```swift
public protocol LLMProvider: Sendable {
    var id: String { get }
    /// 失败以 stream 错误的形式结束；调用方可随时取消。
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}
```

`ChatRequest`：`model` / `messages` / `tools` / `systemPrompt` / `temperature` / `maxTokens`。

`ChatEvent`：

| 事件 | 含义 |
|---|---|
| `.textDelta(String)` | 增量正文 |
| `.toolCallDelta(index:id:name:argumentsFragment:)` | 工具调用分片（供调试 / 展示，不必处理） |
| `.toolCallComplete(ToolCall)` | 组装完成的调用（`id`、`name`、`argumentsJSON` 原样透传） |
| `.usage(Usage)` | 输入/输出 token |
| `.finish(FinishReason)` | `stop` / `length` / `toolCalls` / `contentFilter` / `unknown` |

`ToolCall.argumentsJSON` 是**模型原始字符串**，不重新序列化 —— provider 的怪癖（空串、多余空白）能原样回传给下一轮。

## 三家映射

### OpenAI / OpenAI 兼容（Ollama、OpenRouter…）

- 端点：`{baseURL}/v1/chat/completions`
- `stream: true`，并带 `stream_options.include_usage`
- 工具：`tools[].function.parameters` 直接放 JSON Schema
- 流：`choices[0].delta.content` → `.textDelta`；`delta.tool_calls[i]` 按 `index` 累积 → `.toolCallComplete`
- 结束：`finish_reason` 或 `data: [DONE]`

### Anthropic

- 端点：`{baseURL}/v1/messages`；头部 `x-api-key` + `anthropic-version: 2023-06-01`
- `system` 提升到顶层字段，不进 `messages`
- 工具调用：`content_block_start(type=tool_use)` → `content_block_delta(input_json_delta.partial_json)` 累积 → `content_block_stop` 时完成
- 结束：`message_delta.stop_reason`（`tool_use` → `.toolCalls`）

## 注册表

`ProviderRegistry`（actor）：

- 保存 `ProviderConfig`（id / kind / model / baseURL / **keychainAccount**）
- **API Key 不在 config 里**：每次请求前从 `KeychainStore` 读取，config 可安全打日志
- `provider(id:)` 按 `kind` 构造对应 provider

## 错误

`LLMError`：`missingAPIKey` / `invalidConfiguration` / `httpStatus` / `streamEndedEarly` / `malformedEvent` / `cancelled` / `transport`。

取消语义：`Task` 取消 → `byteStream` 的 `onTermination` 取消 URLSession 任务 → `stream` 以 `LLMError.cancelled` 结束。

## 测试基准

用录制 SSE 文本喂 `SSEDecoder` → 解析器，覆盖：文本流、工具调用分片组装、usage、两家请求体结构。网络层不在单元测试里出现。