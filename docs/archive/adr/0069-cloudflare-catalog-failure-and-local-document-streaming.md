# ADR 0069: Cloudflare 目录失败与本地文档流式边界

## Status

Accepted for `0.31.0-dev.85`; network ownership in decision 4 is superseded by ADR 0070.

## Context

Mihon 来源的章节接口可能因 Cloudflare、扩展网络栈或真实插件错误失败。旧兼容逻辑把“没有得到章节”视为无章节 gallery，并创建一个 synthetic “正文”章节，导致错误被隐藏。与此同时，Android SAF `content://` 页面以完整 `Uint8List` 跨 MethodChannel，再写入既有 artifact；大尺寸高分辨率文件产生额外大对象复制和首帧延迟。数据平面的若干默认块仍为 64 KiB，但 sessions 的 64 KiB source/telemetry 聚合又是独立诊断策略。

## Decision

1. `MihonRuntimeDriver` 明确区分章节调用失败、权威目录（包括空目录）与 chapter-list capability 不存在。失败直接冒泡。synthetic gallery 只在 capability 不存在且非空正文页面预检成功时创建。
2. 详情 Presentation 对空权威目录显示错误、重试和 WebView 命令。dev.85 当时由 App composition 绑定插件桥 `openMihonLogin`；该临时所有权已由 ADR 0070 替换为直接注入 `network_bridge.openBrowser`。Presentation 始终不访问 runtime、Cookie 或 transport。
3. Mihon opaque synthetic token 的解析保留在 `plugin_host` 协议适配层。App composition 只通过显式 helper 清理真实目录恢复后的旧 synthetic 持久条目。
4. dev.85 的 Cloudflare 自动兼容最初位于隔离 Mihon runtime network；ADR 0070 已把通用 interceptor/CookieJar/DNS 实现迁到 `network_bridge`，Mihon runtime 仅保留 ABI adapter。30 秒 challenge 与网络失败不得改写为 gallery 的语义不变。
5. transport、storage artifact 与 downloads fallback 的默认 I/O 块设为 256 KiB；sessions 的 64 KiB source wake/telemetry 聚合保持不变。
6. 普通文件由 `FileTransport/RandomAccessFile` 直接 range/chunk 读取。Android document URI 通过 bridge v4 的 `openDocument/readDocumentChunk/closeDocument` 句柄返回流、revision、range/partial 元数据；validator 不匹配时从 0 返回完整响应。
7. 平台流只注入既有 Pipeline。DownloadSession、partial、resume、artifact、decode/upload 和关闭顺序不迁出 owner，也不新增 App/Reader 字节缓存。

## Consequences

- Cloudflare 和插件故障对用户可见并可通过 WebView 恢复，不再污染目录身份。
- 真正没有 chapter-list API 的 gallery 仍可兼容，但需要更强证据。
- 大文件不再作为单个 MethodChannel 对象进入 Reader；SAF 文件仍会按 Pipeline 既有语义写入权威 artifact，以支持 resume/decode，不是旁路或第二缓存。
- bridge protocol 从 v3 升到 v4，Dart/native 必须同时更新并通过静态/owner 测试。
- 需要设备侧验证 WebView challenge、SAF provider range 行为、首帧延迟和句柄释放。

## Rejected alternatives

- 章节调用失败或空列表时无条件创建单章节。
- 在详情 UI 解析 Mihon token 或直接操作 Cookie/OkHttp。
- 把 `content://` 预复制到 App 目录后才创建 Reader source。
- 继续整文件 `readDocument` 作为常规 Reader 路径。
- 把 telemetry 的 64 KiB 聚合一并改为 256 KiB。
- 缩小预取窗口或 lane 来掩盖 I/O/请求问题。
