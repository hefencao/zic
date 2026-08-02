# dev.85 Cloudflare 目录失败、本地大文件与分块审计

## 基线与输入

- 唯一代码基线：用户本次上传的 `zic_v0.31.0-dev.84_mihon-transform-details-metadata`。
- `staged.zip` 仅覆盖同路径文件后继续审查和修正；不得引入其他候选树。
- `mihon-main(2)` 与 `vibevenera-master(4)` 仅只读参考。
- Reader 7/3 下载窗口、2/1 预解码窗口、current/transition 上传和 5/3/2 lane 不变。

## 问题清单

### 编译错误

1. 当前输入未附新的 analyzer/编译日志；必须先应用 staged 闭包，再通过 analyzer、受影响 package 测试、Android 编译或静态提取式契约确认公共 API 调用方完整迁移。
2. staged 新增 Android Cloudflare 类并修改两套 Mihon ABI `NetworkHelper`，必须确认 common sourceSet、构造签名、OkHttp API 与测试源码均被 Gradle 编译闭包覆盖。
3. staged 让 App 直接解析 Mihon synthetic identity 会扩大插件协议泄漏；即使编译可过，也应收口为 catalog 可消费的显式章节语义或由 composition 预先清理，不能让 Presentation 持有 opaque token 解析算法。

### 产品错误

1. Mihon/JMComic 章节目录请求遇到 Cloudflare 或其他真实网络/插件失败时，被“无章节漫画”兼容逻辑吞掉并创建单一“正文”章节；失败不是无章节证据。
2. 真实章节目录加载失败时详情页应显示权威错误，并提供打开来源 WebView 的图标；不得继续显示伪造章节。
3. 仅当目录能力确实不存在、且 synthetic gallery 正文预检得到非空页面时，才允许单章节兼容。
4. 旧持久化 synthetic 章节可能在后续真实目录恢复后继续混入本地详情投影，需要按显式 synthetic 标记淘汰，但不能由 UI 自行理解 Mihon opaque identity。
5. Cloudflare challenge 处理必须复用 Mihon source client/CookieManager，并允许用户通过已有宿主 WebView 完成交互；不得在 App 建站点专用网络旁路。
6. 本地 Android `content://` 高分辨率大图当前通过 MethodChannel 一次性读取完整 `Uint8List`，再进入 LoaderTransport/DownloadSession，造成大对象复制和首帧延迟。

### 性能问题

1. artifact 默认读取块为 64 KiB；对大文件会产生过多异步读、写和唤醒。数据传输默认块应提升为 256 KiB，但 source-progress/trace 的 64 KiB 聚合量子是诊断策略，不应随意改变。
2. Android document URI 当前完整字节跨 MethodChannel，Dart 与 Android 至少各持有一份大缓冲；应改为平台流式响应，按范围/分块直接喂给现有 DownloadSession。
3. 本地普通路径已经可由 `FileTransport.openRead` 流式处理，不应回退到 `readAsBytes`；content URI 也应获得同等的受控流式能力。
4. 不能通过缩小 Reader 窗口、关闭预下载或降低 lane 并发掩盖本地 I/O 或 Cloudflare 请求错误。

### 测试错误

1. 章节目录失败回归必须断言错误向上冒泡且 synthetic factory 不被调用，不能只断言最终章节数量。
2. WebView 图标测试应使用稳定 key/callback，不能依赖错误文案包含匹配。
3. 本地流式测试必须使用可控 chunk stream/range，验证没有调用完整字节 loader；禁止固定 pump、真实 socket 和大文件实际等待。
4. 256 KiB 默认块应在拥有它的 storage/transport/package 单元测试中验证；App 不重复测试底层分块算法。

## 所有权清单

| 状态/资源/命令/生命周期 | 当前所有者 | 正确所有者 | 本轮动作 |
|---|---|---|---|
| Mihon 详情/章节调用结果与失败 | `plugin_host_bridge/MihonRuntimeDriver` | 同左 | 区分“目录能力不存在/权威空”与“调用失败”；失败直接冒泡 |
| synthetic gallery 判定 | runtime driver 生成 opaque chapter token，旧条目可能持久化 | `plugin_host_bridge` 判定资格；`plugin_host` 协议适配层解析明确 synthetic identity | App composition 仅调用 helper 协调旧条目；Presentation/catalog storage 不解析 token |
| Cloudflare challenge 自动尝试 | Mihon source `NetworkHelper.client` | `plugin_host_bridge` 的 Mihon runtime compatibility network | 按 Mihon client 语义安装 interceptor，共享 Android CookieManager |
| 手动 WebView 访问命令 | dev.85 临时使用 `plugin_host_bridge.openMihonLogin`；dev.86 已由 ADR 0070 迁到 `network_bridge.openBrowser` | App composition 注入只读/命令 callback，详情 Presentation 仅显示按钮 | 详情失败态增加 callback，不直接访问 Cookie/runtime/session |
| 章节详情错误 UI | `apps/app/comic_details` | 同左（Presentation 局部投影） | 显示错误、重试、WebView 图标，不伪造目录 |
| 本地 content URI descriptor/读取 | `local_media_bridge` | 同左的平台能力；上层只接收 `ByteResponse` | 增加流式/range 读取能力，生命周期由 bridge response owner 关闭 |
| Reader 本地页面 transport | `pipeline_runtime` 的 LoaderTransport/DownloadSession | 同左 | composition 注入 content URI `openResponse`，不建立第二 session/cache |
| 普通文件路径读取 | `transport/FileTransport` | 同左 | 保持直接 `openRead`，避免 `readAsBytes` 路径 |
| artifact 读块默认值 | `storage/Artifact.readChunks` | 同左 | 64 KiB 改为 256 KiB，补 owner 测试 |
| source progress telemetry 聚合 | `sessions/source_progress` | 同左 | 保持 64 KiB；它不是传输 chunk 大小 |
| Reader 预取/解码/上传窗口 | `pipeline_runtime` | 同左 | 不变 |

## 被否决方案清单

1. **章节请求失败后生成“正文”单章节**：真实失败不是无章节证据，会隐藏 Cloudflare/插件错误并打开错误正文。
2. **只凭章节列表为空判定 gallery**：必须证明目录能力不可用，并以非空正文预检确认 synthetic gallery。
3. **在 App/Reader 识别 JMComic、Cloudflare 或解析 Mihon opaque token**：违反插件隔离与 API 边界。
4. **把自动隐藏 WebView 当成唯一恢复路径**：交互式 challenge 可能无法自动完成，失败态必须提供用户可见 WebView 入口。
5. **所有 content URI 完整 `readDocument` 后跨 MethodChannel**：高分辨率大文件产生大对象复制和明显延迟。
6. **把 content URI 复制到 App 目录后再当普通文件作为常规路径**：重复占用空间并延迟首帧；应流式进入现有 session/artifact，是否持久 promotion 仍由 downloads/session 所有。
7. **把 64 KiB telemetry 聚合量子一起改为 256 KiB**：会改变诊断及时性；传输块与 telemetry 聚合不是同一所有权。
8. **缩小 7/3、2/1 窗口或降低 5/3/2 lane**：只能掩盖请求/I/O 错误，已明确禁止。
9. **为通过测试改变产品逻辑、使用固定 pump/timeout 或真实 socket**：测试必须服从权威状态和可控 Future/Stream。


## 实际实现

- staged 文件已先覆盖唯一 dev.84 工作树；Mihon driver 将章节异常保存为 `chapterFailure` 并在 synthetic 选择前抛出，`chapterCatalogAvailable` 阻止权威空目录进入 fallback。
- Cloudflare interceptor 接入两套 Mihon ABI runtime network，共享 Android CookieManager、过滤 WebView headers、等待 30 秒并在失败时提示打开来源登录页。
- 详情页以稳定 key 显示 WebView/retry；App composition 在 dev.86 直接绑定 `network_bridge.openBrowser`。真实目录恢复时通过 `plugin_host.isSyntheticMihonChapterIdentity` 清理旧 synthetic library entry。
- `defaultTransportChunkBytes`、artifact 默认块和下载 fallback 块统一为 256 KiB；64 KiB source progress/Trace 量子未修改。
- 本地普通路径使用 RandomAccessFile 分块。Android document bridge 升级到 v4，以 handle open/readChunk/close 返回流和 range 元数据；取消、读完或 detach 均关闭句柄，validator 不匹配返回完整响应。
- Reader 页面仍进入既有 `PipelineReaderSession -> DownloadSession -> artifact -> decode/upload`，没有新增 App/Reader 私有字节缓存、session 或预取实现。

## 当前环境验证

- 通过：repository/Dart structure、library directive order、dev.75–dev.85 ownership gates、Mihon entry/payload/ABI/classloader/read-only/chapter contracts、Venera response/preflight/source binding、Reader layout/demand/streaming、UI architecture、external login/settings、Android runtime/Trace/native header 等当前可执行静态与宿主契约。
- `tool/check_webp.sh` 需要从外网获取上游源码，当前环境 DNS 不可用，未完成；本轮未改 WebP native 实现。
- 当前容器没有 Flutter/Dart SDK、Android Gradle wrapper、Cargo/rustc，无法执行 analyzer、Dart/Flutter tests、kernel snapshot、Android debug/release 或 Rust tests。以上不得被静态门禁替代。
- 仍需真机验证 Cloudflare 交互、真实 gallery、SAF provider 的 range/取消、首帧延迟和内存峰值。
