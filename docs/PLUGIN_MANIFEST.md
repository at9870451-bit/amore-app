# 插件契约（manifest v1 / 三种类型 / JS 宿主 API）

## manifest.json

```json
{
  "schemaVersion": 1,
  "id": "io.github.alice.weather",
  "name": "Weather",
  "version": "1.2.0",
  "minHostVersion": "1.0.0",
  "type": "js",
  "entry": "index.js",
  "author": { "name": "Alice", "github": "alice" },
  "description": "查询天气",
  "icon": "icon.png",
  "permissions": ["network:api.open-meteo.com", "storage", "secrets", "notify"],
  "tools": [{
    "name": "get_weather",
    "description": "获取城市天气",
    "inputSchema": { "type": "object", "properties": { "city": { "type": "string" } }, "required": ["city"] }
  }],
  "settings": [{ "key": "unit", "type": "enum", "options": ["C", "F"], "default": "C" }]
}
```

| 字段 | 约束（`ManifestValidator` 实际执行的检查） |
|---|---|
| `schemaVersion` | 必须为 `1` |
| `id` | 反向域名 `^[a-z0-9]+(\.[a-z0-9][a-z0-9-]*)+$`，≤128 字符 |
| `version` / `minHostVersion` | 语义版本 `^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$`；host 版本用 major/minor/patch 数值比较 |
| `tools[].name` | `^[a-z_]{1,64}$`，且不得重复 |
| `permissions[]` | 必须在白名单内（见下） |
| `entry` | `js` 类型必填、必须是相对路径、以 `.js` 结尾、不含 `..` |
| `server` | `mcp` 类型必填（`{ url, auth: none|bearer|oauth }`） |
| `templates` | `prompt` 类型必填且非空 |
| `settings[].key` | 不得重复；`enum` 必须给 `options` |

## 权限白名单

| 权限 | 含义（同意页中文文案） |
|---|---|
| `storage` | 保存插件自己的数据（最多 1 MB，按插件隔离） |
| `secrets` | 读取你在设置里为这个插件填写的密钥 |
| `notify` | 发送通知 |
| `network:<host>` | 通过 HTTPS 访问该域名 |

`<host>` 必须是不带 scheme / path / 端口 / 通配符的裸域名。

## 安装管线（`InstallPipeline`）

1. 下载（`PluginDownloading`，累计 > 10 MB 立即中止）
2. **SHA256** 与索引条目比对
3. **Ed25519** 验签，签名对象是 zip 的 SHA256 摘要
4. `PluginArchive.unpack`：拒绝绝对路径 / `..` / 反斜杠 / 盘符 / 符号链接；≤500 条目；解压后再确认路径仍在目标目录内
5. 解压后**重新校验** manifest：`id`、`version` 必须与索引一致
6. 权限必须是用户已批准的**子集**
7. 原子移动到 `Plugins/<id>/<version>/`
8. 写入 `installed.json`（保留 `previousVersion`）

失败路径：临时目录整块删除，不留半成品。
回滚：上一版本目录存在则回滚并更新记录；不存在则删除当前版本并移除记录。

## JS 宿主 API（`PluginRuntimeJS`）

插件以 IIFE 形式提供：

```js
globalThis.plugin = {
  onLoad(ctx) {},
  tools: {
    get_weather: async (args, ctx) => ({ tempC: 22 })
  }
};
```

注入的 `amore` 全局，全部返回 Promise：

| API | 约束 |
|---|---|
| `amore.http.fetch(url, {method, headers, body})` | 必须 **https**；host 必须在 manifest 的 `network:` 白名单；响应 ≤ 5 MB |
| `amore.storage.get/set/remove(key)` | 需要 `storage` 权限；按插件 id 隔离；总量 1 MB |
| `amore.secrets.get(key)` | 需要 `secrets` 权限；值来自 Keychain |
| `amore.notify(title, body)` | 需要 `notify` 权限 |
| `amore.log.info/error(message)` | 无额外权限，写入宿主日志 |

安全：

- 启动前删除 `eval` 与 `Function` 构造器。
- `setTimeout` / `clearTimeout` 由宿主调度（不占用 JS 线程）。
- 单次工具调用 30 s 超时；**连续 3 次超时自动禁用插件**。
- 未捕获异常经 `exceptionHandler` 转成 `PluginError.runtime`。

## MCP 类型

`MCPClient` 走 JSON-RPC 2.0 + Streamable HTTP：

1. `initialize` → 从 `Mcp-Session-Id` 响应头取会话，后续请求回传
2. `tools/list` → 注册为 `server__tool`
3. `tools/call` → 拼接 `content` 中 `type == "text"` 的块
4. 认证：`tokenProvider` 闭包（Bearer 存 Keychain，不写进 manifest）

## prompt 类型

`templates: [{ name, prompt, variables }]`，在输入框用 `/` 命令触发，不改后端。