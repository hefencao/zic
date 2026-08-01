# dev.79 稳定性恢复审计

## 问题清单

### 编译错误
- `pipeline_runtime` 公共能力接口曾漏导 `RendererKind`；dev.78 已补齐，dev.79 必须保持全调用方闭包。
- `UploadRegistry` 曾越权引用 `PlaybackState`；dev.78 已改为查询 `UploadSession.playbackRunning`，dev.79 不得恢复枚举泄漏。

### 产品错误
- Venera JavaScript source 的 `loadComic/loadInfo` 在运行一段时间后出现 `null.children`。当前同一 WebView 允许多个 source operation 并发，且宿主额外包裹了 60 秒 raw `loadInfo` cache；两者都越过了非重入 source 脚本和 `resource_cache/catalog` 的所有权边界。
- 非 HTTP 的 source-owned 封面 locator（例如 `mihon:resource:`）被 App 当成本地文件读取；durable cache 命中时假装正常，失效后无法回源。
- 同一封面 identity 的完整 encoded-image resolution 未统一合并，多个页面入口会重复执行 durable lookup / loader 路径。
- Reader WebP decode 异常只停留在 coordinator trace，Upload/output 未投影失败，页面因此可以永久停在 loading。
- demand 重入、有限动画 EOF、source epoch 更新和 output retirement 之间仍有不完整状态转换，造成流式播放停止或页面重入后无帧。
- 连续阅读未知页面高度依赖 mutable `currentIndex`，页面 extent 在滑动中改变；异步尺寸回报又用中心分数 jumpTo，形成持续回拉。
- 自适应布局只使用 manifest/source direction；运行时确认的 animated WebP 没有成为更高优先级证据，因此明显动画仍可能被 source vertical 方向判为连续阅读。

### 性能问题
- Venera runtime 允许共享全局 scratch 的 source operation 并发，并不能提升正文字节 transport；只增加脚本竞态与失败重试。
- 封面 custom locator cache miss 后重复请求且不能正确回源。
- 连续阅读尺寸回报触发不必要的多次跳转和重布局。

### 测试错误/缺口
- 缺少 Venera source operation 串行、Mihon 保持并发的契约测试。
- 缺少禁止 plugin_host raw `loadInfo` cache 的静态门禁。
- 缺少 custom source locator 封面回源测试。
- 缺少 decode failure 到 page output failure 的 owner-package 回归。
- 缺少未知页面 extent 与 currentIndex 无关、几何更新不回拉的测试。
- 缺少 runtime animated observation 覆盖 source vertical 的自适应测试。

## 所有权清单

| 状态/资源/命令/生命周期 | 当前所有者 | 正确所有者 | dev.79 动作 |
|---|---|---|---|
| Venera source operation 并发 | 通用 `_RuntimeInvocationGate` | `plugin_host` 按 runtime format 的调用契约 | Venera source invocation 单 in-flight；Mihon 不变 |
| `loadComic/loadInfo` cache | WebView bootstrap raw object wrapper + `resource_cache` | `resource_cache/catalog` | 删除 bootstrap raw cache |
| source-owned cover locator 解析 | App 仅按 HTTP 判定 | `ComicSourceResourceGateway` + `resource_cache` | 所有 external scheme 进入 gateway |
| encoded cover resolution 合并 | byte loader `_inFlight` | `ResourceCacheManager` | 合并完整 encoded-image resolution |
| decode 错误 | `DecodeSession`/coordinator trace | `DecodeSession` 权威失败，`UploadSession`/page output 只读投影 | 补 failure 状态传播 |
| WebP cursor replay | `DecodeSession` | `DecodeSession` | 明确 EOF/重入/source epoch 转换 |
| 页面显示 surface | `PipelinePageOutputStream` | 不变 | 保留最后成功 surface；失败明确投影 |
| 连续阅读未知 extent | `ReaderView` 且依赖 currentIndex | `ReaderView` Presentation 几何 | 使用稳定占位 extent |
| 几何变更滚动锚点 | `ReaderView` 中心 fraction jump | `ReaderView` 顶部可见像素锚点 | 仅补偿真实 extent 差，不与用户滚动竞争 |
| animated capability | `LocalImagePlayer` 发现但只用于控制条 | `reader_runtime` observation adapter | 作为 adaptive 的高优先级运行时证据 |

## 被否决方案清单

- 不通过降低 Pipeline 下载窗口、预解码窗口、上传窗口或 lane 并发掩盖问题。
- 不给 App/Reader 新建第二套封面缓存、页面字节 LRU、WebP decoder 或 session registry。
- 不把 Venera source 失败简单改成无限重试；先消除并发和 raw cache 竞态。
- 不保留 WebView 内 `loadInfo` raw object cache；详情缓存属于 `resource_cache/catalog`。
- 不把所有插件一律串行；只约束已知非重入的 Venera JavaScript source operation，Mihon 隔离运行时维持既有并发。
- 不用固定 timer、负位移、页面重叠或强制 jumpTo 掩盖连续阅读回拉。
- 不把 `.webp` 扩展名直接等同于动画；只有 runtime/header 确认 animated 才覆盖 source direction。
- 不为无限 loading 永久保活所有 cursor/texture；错误必须可见，重入必须由稳定 identity 重建。


## 实施结果

- Venera source operation 使用 format-aware gate 单 in-flight；Mihon 使用配置并发。删除 `__zicInstallComicInfoCache` 及 60 秒 raw `loadInfo` cache。
- custom source locator 统一进入 `ComicSourceResourceGateway`；完整 encoded image resolution 增加 owner-level in-flight 合并。
- source listener 现在覆盖 ready、增长、seal 和 failure，并可立即投影已经 ready 的 source。Decode failure 进入 Upload/page output，不再停在 loading。
- 连续阅读未知 extent 改为稳定占位，尺寸变化采用 idle top-pixel anchor；滚动事件取消待恢复 anchor。
- runtime-confirmed animation 产生 `runtime-animation` adaptive profile，显式漫画方向覆盖保持最高优先级。

## 验证结果

- 已通过仓库结构、Dart directive、Pipeline compile boundary、dev.75–79、Reader streaming、纵向几何、source binding 和 UI Architecture 静态门禁。
- 已在工作树与最终 ZIP 系统解压副本上，使用用户提供的 libwebp 1.6.0 本地源码完成 host build 与 incremental/loop fixtures。
- 工作树与最终 ZIP 系统解压副本均通过结构、dev.75–79、Reader/Pipeline/UI、Android runtime/config、Mihon ABI/entry/payload/read-only/chapter/classloader、Venera network/native/headers/preflight/bootstrap、外部来源设置/登录和 native header 契约。
- 当前环境缺少 Flutter/Dart SDK、Cargo/rustc、Gradle/Android wrapper；相关 analyzer、Dart/Flutter/Rust 测试、Android 构建和真机行为不能声明通过。
