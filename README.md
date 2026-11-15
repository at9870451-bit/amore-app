# Amore · 个人 AI 助理（SwiftUI 多平台）

P0 交付：工程骨架、全部 SPM 模块壳、AppShell（TabView / NavigationSplitView + Router + DeepLink）、CoreKit 完整实现与测试。

## 要求

- Xcode 16+（Swift 6）、iOS 18 SDK
- XcodeGen（`brew install xcodegen`）

## 生成工程并编译

```bash
cd Amore
xcodegen generate                       # 生成 Amore.xcodeproj（多平台 target）
# 若你的 XcodeGen 低于 2.40 报 "platform must be a string"，
# 把 project.yml 的 `platform: [iOS, macOS]` 改成 `destinations: [iOS, macOS]`
open Amore.xcodeproj

# 命令行编译
xcodebuild -project Amore.xcodeproj -scheme Amore \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

xcodebuild -project Amore.xcodeproj -scheme Amore \
  -destination 'platform=macOS' build
```

## 测试

```bash
# CoreKit（Swift Testing）
swift test --package-path Packages/CoreKit

# 全量（App 工程里）
xcodebuild test -project Amore.xcodeproj -scheme Amore \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## 手动验证

1. **三平台启动**：iPhone 模拟器显示 TabView（Chat/Agents/Tasks/Memory/Profile）；iPad 宽度 ≥720pt 与 macOS 显示 NavigationSplitView。
2. **深链**：
   ```bash
   xcrun simctl openurl booted "amore://plugin/install?id=io.github.alice.weather"
   ```
   预期：当前 Tab 推入 `Plugin detail / Install plugin` 占位页，标题显示插件 id。
   参数非法（例如 `id=Weather`）时不应路由。
3. **CoreKit 测试**：`swift test --package-path Packages/CoreKit` 全绿。

## 模块与依赖方向

```
Features/{Chat,Marketplace,PluginManager,Memory,Settings}
  → AgentKit / MarketplaceKit / MemoryKit / PluginKit / LLMKit
  → NetworkKit / SecurityKit / DesignSystem
  → CoreKit
```

`PluginRuntimeJS`、`PluginRuntimeMCP` 由 PluginKit 侧在 P5/P7 接入，当前为可编译空壳。

## P1 预留接口（下一阶段实现）

- `SecurityKit`：`KeychainStore` actor（service 隔离 + 可选 Face ID）、`CryptoService.sha256(file:)`、`verifyEd25519(signature:data:publicKey:)`
- `NetworkKit`：`HTTPClient` actor（重试/退避、ETag 磁盘缓存、`AsyncStream<Progress>` 下载）、`SSEParser`（`AsyncSequence`）
- 这些类型将作为 `DependencyContainer` 的可选字段注入；P0 的容器已支持值类型扩展，不破坏现有调用点。

## 约定

- 文件 ≤400 行；public API 有 DocC 注释。
- 无强制解包；IO 不在主线程；日志不写敏感字段。
- 每个模块自带 `enum XxxError: LocalizedError, Sendable`。