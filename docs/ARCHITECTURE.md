# Amore 架构说明

## 目标

个人 AI 助理，原生多平台（iOS 18 / macOS 15）。本仓库只包含 C 端；Agent 能力全部在本机进程内运行，没有远程业务后端。

## 分层

```
Presentation  SwiftUI View + @MainActor @Observable Store
     ↓
Domain        Entity / UseCase / Repository 协议
     ↓
Data          Repository 实现、DTO、Mapper
     ↓
Infrastructure NetworkKit、SecurityKit、MemoryKit、PluginRuntime*
     ↓
CoreKit       Logger / AppError / Clock / UUID / DI / FeatureFlag / Signposts / Telemetry
```

规则（已在代码中执行）：

- View 只做 UI，副作用在 Store。
- Store 只依赖 UseCase / Repository 协议，标 `@MainActor`。
- 所有 IO 在 actor 或 `nonisolated async` 函数里。
- 跨隔离域传递的类型必须是 `Sendable`（快照结构体，模型不逃逸）。

## 模块依赖图

```
App
 ├── CoreKit
 ├── DesignSystem
 ├── SecurityKit ──→ CoreKit
 ├── NetworkKit ───→ CoreKit
 ├── LLMKit ───────→ NetworkKit, SecurityKit, CoreKit
 ├── PluginKit ────→ CoreKit (+ ZIPFoundation)
 ├── AgentKit ─────→ LLMKit, PluginKit, CoreKit
 ├── MemoryKit ────→ CoreKit, LLMKit, NetworkKit
 ├── PluginRuntimeJS ──→ PluginKit, CoreKit
 ├── PluginRuntimeMCP ─→ PluginKit, NetworkKit, CoreKit
 ├── MarketplaceKit ───→ NetworkKit, SecurityKit, PluginKit, CoreKit
 └── Features/{Chat,Marketplace,PluginManager,Memory,Settings}
```

依赖是单向的，无环。`PluginRuntimeJS` 不依赖 `AgentKit`；把 JS 工具变成 `AgentTool` 的适配器放在 App 层（`App/Services/PluginToolAdapter.swift`）。

## 关键线程模型

| 组件 | 隔离 |
|---|---|
| `HTTPClient` / `KeychainStore` / `ToolRegistry` / `PermissionGateway` / `AgentLoop` / `MemoryStore` / `VectorIndex` / `InstalledRegistry` / `InstallPipeline` / `MCPClient` | `actor` |
| `JSPluginHost` | `actor`，内部所有 JS 在**单条串行队列**上执行（`JSContext` 非线程安全） |
| `AppLockController` | `actor` |
| 根视图 / Stores | `@MainActor` |
| `CryptoService` / `ContextBuilder` / `Signposts` | `Sendable` value types，无状态 |

## 一次对话的数据流

```
用户输入
  → ChatStore(@MainActor) 追加用户消息
  → AgentLoop.events(for:)            (actor)
      ContextBuilder：system + top-k 记忆 + 最近 N 轮（按 token 预算从旧到新裁剪）
      LLMProvider.stream(request)     → AsyncThrowingStream<ChatEvent>
      toolCallComplete → PermissionGateway.authorize → AgentTool.execute（30s 竞速超时）
      → AgentEvent（textDelta / toolCallStarted / Finished / …）
  → ChatStore 消费事件，逐 token 更新（同一 message id 替换，列表长度不变）
  → MemoryStore.ingest(...)           一轮结束后抽取记忆并去重（0.92）
```

## 依赖注入

`DependencyContainer`（`Sendable` struct）经 `@Entry` 注入环境：

```swift
RootView().environment(\.dependencies, .live)   // live / preview / test
```

因为它是值类型，P1 之后新增的 `KeychainStore`、`HTTPClient` 等可以直接加字段，不影响既有调用点。

## 已知边界

- 插件只能是 `js` / `mcp` / `prompt`，**不下载任何原生二进制**（App Store 2.5.2）。
- 无远程业务后端；LLM 请求直连用户配置的 provider（OpenAI / Anthropic / 兼容端点）。
- 云端同步通过 FeatureFlag 预留，未实现。