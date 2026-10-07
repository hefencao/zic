# dev.90 Mihon runtime 与 canonical identity 审计

## 问题清单

### 编译错误

- Mihon ABI asset 独立编译只包含 network runtime source；`AndroidCookieJar -> AndroidBrowserCookieSession -> NetworkBrowserSnapshotStore` 的最后一项原位于 main source，导致 unresolved reference。

### 产品错误

- 同一 Mihon source/作品在更新区出现两份卡片。
- 一个 alias 显示 342 章，另一个显示 1 章；刷新后仍保持各自目录。
- Remote details 以前要求返回 comic/chapter raw ID 与 browse summary 完全相等，canonical alias 即使加载成功也可能显示红叉。

### 性能问题

- 未发现新增网络或解码重复请求是此次重复卡片的根因。alias 投影在内存中按已有 library snapshot 线性分组，不新增来源调用。

### 测试错误

- 旧共享浏览器编译测试只覆盖 Activity/store，没有编译 `AndroidCookieJar -> AndroidBrowserCookieSession -> NetworkBrowserSnapshotStore` 完整链；现已扩展为同一次 Kotlin 编译。
- `resolveComicDetailsRoute` 仅被门禁/文档保活，生产无调用，且其精确 ID 规则已退化。

## 所有权清单

| 状态/资源 | 当前正确所有者 | 说明 |
|---|---|---|
| 浏览器原子 snapshot 文件 | `network_bridge` runtime Kotlin | 主 AAR 与隔离 Mihon ABI 共享实现 |
| Mihon opaque comic locator | `plugin_host`/Mihon adapter | 传回插件加载，不由 App 解码 |
| 同源 canonical identity | source adapter capability | comparison-only URL 规范化 |
| library alias 合并和优选 | `catalog` | 只读投影，保留原始 locator |
| source card 到本地详情路由 | App composition | 消费 catalog/source capability |
| 详情 raw/canonical 匹配 | Presentation 注入 matcher | 不持有插件算法 |
| 目录回归保护 | App composition + durable catalog | canonical group 级别保护 |
| alias 诊断 | telemetry/DebugTrace 投影 | 只记录 hash、长度和数量 |

## 被否决方案清单

- **把 canonical URL 直接写回 `comicId`**：会丢失扩展可能依赖的 SManga memo/字段，并改变 chapter owner。
- **按标题合并漫画**：不同作品可同名，跨来源也不等价。
- **迁移所有历史 chapter ID 到新 alias**：chapter opaque token 内含原 comic locator，会破坏加载和下载 identity。
- **在 App 重新解析 Mihon Base64**：泄漏插件协议并形成第二解析实现。
- **保留精确 ID 路由 facade 再加例外**：生产无调用且规则与 canonical routing 竞争。
- **复制 snapshot store 到 main/runtime 两份**：会产生两个实现和修复漂移；source set必须复用同一文件。

## Trace 证据

用户上传的 310 条事件中，同一 `mihon:6286738698187452081` source 出现长度 439 与 440 的两个 identity。长度 439 的强制刷新由 1 章恢复为 342 章；长度 440 的多次本地刷新一直为 1 章。两者 `syntheticChapterCount` 均为 0，排除 synthetic revision 退化作为直接原因。
