# Amore 发布前检查清单（P8/P9）

## 构建与测试
- [ ] `xcodegen generate` 后 iOS / iPadOS / macOS 三个 target 均能 build
- [ ] `swift test --package-path Packages/<X>` 全部通过（CoreKit / SecurityKit / NetworkKit / LLMKit / AgentKit / MemoryKit / PluginKit / PluginRuntimeMCP / MarketplaceKit）
- [ ] `PluginRuntimeJS` 的 4 个验收点：异步调用、越权 fetch 拒绝、超时禁用、storage 隔离
- [ ] 覆盖率：Domain 层 ≥ 80%（`xcodebuild test -enableCodeCoverage YES`）

## 隐私与安全
- [ ] `PrivacyInfo.xcprivacy` 已加入 App target（UserDefaults / FileTimestamp / DiskSpace 三项理由齐全）
- [ ] 无 tracking 域名；无广告 SDK
- [ ] API Key 只存 Keychain（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）
- [ ] 日志不含 token / 明文 prompt（`privacy: .private`）
- [ ] App 锁（Face ID）可开启，退后台立即锁定
- [ ] 导出全部数据 + 清除全部数据两个操作都真实可用

## 插件合规
- [ ] 只允许 `js` / `mcp` / `prompt` 三种类型，无原生二进制下载路径
- [ ] JS 沙箱禁用 `eval` / `Function`
- [ ] `amore.http.fetch` 强制 https + manifest host 白名单 + 5MB 上限
- [ ] 安装链路 SHA256 + Ed25519 双校验，zip slip 防护有测试
- [ ] 卸载会清理代码 / storage / secrets / 权限记录

## 本地化与无障碍
- [ ] `Localizable.xcstrings` 至少 en / zh-Hans / zh-Hant 完整
- [ ] Dynamic Type 到 AX3 不截断关键按钮
- [ ] VoiceOver 每个按钮有 label，图标按钮均有 accessibilityLabel
- [ ] 深色模式下对比度达标

## CI
- [ ] `.github/workflows/ci.yml` 在 PR 上跑通（SPM 矩阵 + App 构建 + lint）
- [ ] 首次构建需解析 ZIPFoundation；CI 无网时需 vendor

## 交付
- [ ] README：架构图、模块依赖图、DI 说明
- [ ] 接口文档：LLM provider / MCP / 插件 manifest
- [ ] 迁移说明：MemoryKit schema 版本与迁移策略
- [ ] 已知限制清单（JS 运行时未验证、P6 UI 未落地）
