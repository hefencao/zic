# zic Architecture

本文件描述当前稳定的所有权、依赖方向、数据流和生命周期。它不记录版本历史、单轮 Trace 结论、测试通过情况或待办事项。

## 1. 架构目标

- 当前页资源优先，邻页工作不得使 current 饥饿。
- 同一资源 identity 只有一个权威 session、artifact 和活动 writer。
- Reader 只提交 observation 与用户命令，不直接操作 transport、session、artifact、decode/upload lane 或 texture。
- 平台能力从 composition root 注入，核心包不反向依赖 Android、Flutter plugin 或 FFI 实现。
- 每个可变状态只有一个权威所有者；Presentation 只消费只读投影。
- 资源创建者负责关闭 owned 对象，外部注入对象不得被错误关闭。

## 2. 分层

```text
Presentation
  apps/app
  local_media_ui
  reader_runtime
        |
Application / Composition
  downloads_bridge
  pipeline_native
  storage_bridge
  network_bridge
  plugin_host_bridge
        |
Policy / Runtime
  pipeline
  pipeline_runtime
  downloads
  sessions
        |
Domain / Data contracts
  domain
  catalog
  media
  transport
  storage
  resource_cache
  telemetry
        |
Platform / Native implementation
  bridge
  texture_bridge
  runtime_bridge
  native/media_core
```

依赖必须向下或指向稳定抽象。底层包不得读取 Widget、路由、页面选择或 App controller 状态。

## 3. 包所有权

### `domain`

只定义领域 identity、值对象和不可变实体。不得依赖 UI、插件、网络、缓存、数据库或平台桥。

### `catalog`

拥有漫画、章节、来源抽象、manifest 和元数据合同。它不拥有章节正文下载、解码、Reader 控制或页面 artifact。

### `resource_cache`

是封面、详情、搜索和其他网络响应缓存的唯一所有者，负责容量、TTL、in-flight 合并和失效。页面正文 artifact 不进入该缓存平面。

### `transport`

定义可取消、可分块的 encoded-byte transport 和内容识别合同，不拥有持久 artifact 或 Reader 策略。

### `storage`

拥有 partial artifact、校验、seal、原子 promotion 和持久索引。它不决定 Reader demand。

### `downloads`

拥有持久下载任务、DownloadSession 投影、resume、整章/整本调度和下载状态。下载算法不得在 App 页面重复实现。

### `media`

定义 encoded source、cursor、frame、output 和只读 timing capability。它不选择页面角色或平台实现。

### `sessions`

拥有 Download/Decode/Upload session、claim、lease、frame holder、播放 timer 和生命周期协调。session 状态不得暴露为 Presentation 可变对象。

### `pipeline`

拥有 `ReaderObs` 到资源角色和 `DemandPlan` 的纯策略与 diff。默认角色窗口和 lane 权重属于该层。

### `pipeline_runtime`

是 Reader 资源会话的唯一运行时所有者，组合 download、decode、upload、prefetch、retry、进度和 output stream。它创建并按依赖逆序关闭 owned session。

### `pipeline_native`

把 `SourceFactory`、native cursor、frame uploader 和 output projector 作为一个原子 capability 注入 `pipeline_runtime`。核心 Pipeline 不直接创建 `NativeSourceFactory`。

### `reader_runtime`

只负责 Reader Presentation、用户交互、尺寸投影和 `ReaderObs` 适配。它不创建、选择或关闭 Pipeline session。

### `reader`

拥有基础 Reader observation 模型和通用 Flutter reader widget，不拥有下载、缓存和 native media。

### `plugin_host`

拥有插件信任、权限、请求计划、身份适配和生命周期。插件不能获得导航、Reader、demand、artifact、缓存或 App 状态权限。

### `plugin_host_bridge`

实现 Android 隔离进程、Mihon/Venera runtime 适配和 IPC。普通图片正文应由宿主 transport 流式进入统一 Pipeline；需要 runtime transform 的响应必须显式声明能力。

### `network_bridge`

拥有 Android 可见浏览器、Cookie/localStorage 快照、challenge 恢复和共享网络平台能力。Debug UI 和插件 UI 只能调用 facade，不读取 Cookie 值或底层文件。

### `bridge`

提供稳定 Dart FFI 入口及 native source/cursor/frame ABI。它拥有进程级 native decode worker pool，但不拥有 Reader 页面角色。

### `texture_bridge`

拥有 Android texture lease、SurfaceProducer、RGBA blit、schedule 和 release。它不拥有播放 timer、页面 demand 或 frame decode。

### `apps/app`

只负责 composition、导航和页面。不得定义缓存算法、下载算法、预取窗口、页面保活、插件传输或解码器。

## 4. Reader 数据流

```text
Reader interaction / viewport / presentation size
  -> ReaderObs
  -> pipeline policy
  -> DemandPlan
  -> pipeline_runtime reconcile
  -> DownloadSession / DecodeSession / UploadSession
  -> PipelinePageStream
  -> reader_runtime presentation
```

Reader 可以提交：

- 当前 fractional position；
- stable page；
- 阅读方向和交互状态；
- presentation 尺寸；
- pause、resume、speed、jump 等用户命令。

Reader 只能消费：

- `PipelinePageStream`；
- 只读进度；
- texture surface 或 ImageProvider；
- 不可变错误和状态投影。

Reader 不得接触：

- mutable session；
- transport；
- artifact store；
- decode/upload lane；
- native cursor/frame handle；
- texture registry；
- retry 或预下载策略。

## 5. Identity 与去重

同一 locator/request plan 必须先规范化为稳定 identity，再创建 session。首页、详情页和 Reader 不得各自重新请求同一正文。

不同层 identity 不可混用：

- catalog identity：漫画、章节和来源定位；
- download identity：可恢复字节流和 artifact；
- decode identity：source epoch、格式和目标尺寸；
- upload identity：decode output 与 renderer；
- presentation identity：页面位置与只读 output。

source reset、重下、真实尺寸变化或 request plan revision 必须改变相应 epoch/revision。旧 epoch 结果不能覆盖新状态。

## 6. 资源角色和默认策略

默认页面窗口：

- 下载：current + 前 7 / 后 3；
- 页面预解码：current + 前 2 / 后 1；
- 上传：current 与 transition；
- scheduler lane 权重：5 / 3 / 2。

current 必须保留高优先级 decode 能力。策略变化必须由实验、Trace 和设备验证支持，不能通过缩小窗口或降低并发掩盖 identity、流量或生命周期错误。

50% 翻页交接：

- 新 stable page 在 midpoint 成为 current；
- 旧页在仍可见时保留 transition output；
- transition 暂停播放，但不能因角色变化产生 targetless demand gap；
- same-key transition→current 不取消不可中断 native decode/upload，完成后按最新 demand 跟进。

## 7. Animated WebP 路径

```text
transport / artifact stream
  -> media encoded source
  -> native source ingress
  -> demux metadata
  -> Dart decode worker slot
  -> libwebp single-thread frame decode
  -> target-canvas premultiplied RGBA
  -> retained native frame
  -> UploadSession
  -> Android texture or Flutter fallback
```

稳定约束：

- 两个 Dart decode isolate 进程期常驻；
- current 保留一个高优先级槽；
- libwebp 帧内单线程，不安装额外 persistent `WebPWorkerInterface`；
- current 保留两个 successor，transition 保留一个；
- native 输出预乘 RGBA；
- Android 只复制像素，不重复 alpha 预乘；
- metadata 未完成且 source 增长时允许刷新 demux；
- 本地文件和 promoted artifact 默认 1 MiB 分块，普通网络 transport 默认 256 KiB；
- target 使用 contain，不裁切内容，不用负位移或重叠掩盖接缝；
- 几何比例统一使用 `height / width`。

## 8. Android texture 生命周期

`texture_bridge` 创建 texture lease；Upload output 持有 frame claim。replacement 完成前旧 frame 保持有效。最后一个 frame owner 释放后，retired slot 才能释放 producer。

呈现顺序：

1. retain native frame；
2. RGBA blit；
3. 在 platform thread 执行 `SurfaceProducer.scheduleFrame()`；
4. 替换 retained frame；
5. 返回 MethodChannel 结果；
6. UploadSession 记录 presentation 并推进 playback。

平台 timing 仅用于诊断。`scheduleFrame` 的排队和调用时间必须分开记录，不能把 platform-thread queue 误写成 schedule API 自身耗时。

## 9. 插件与网络边界

插件请求先生成 request plan。GET/HEAD 必须零 body，不能携带实体 headers。普通正文由宿主流式 transport 进入同一 DownloadSession；完整 JSON/Base64 RPC 只允许用于明确需要 runtime transform 且有上限的兼容路径。

插件和平台桥不得：

- 导航；
- 创建 Reader；
- 直接提交 demand；
- 读写 artifact store；
- 访问 App controller；
- 输出 Cookie/token 原文到 Trace。

## 10. 缓存与 artifact

资源缓存与正文 artifact 是两个平面：

- `resource_cache`：可重新获取的网络响应；
- `storage`/`downloads`：章节正文 partial、resume 和 promoted artifact。

App 和 Reader 不得建立私有图片字节 LRU。cache hit 也不能共享播放 timer、cursor 或 decode identity。

## 11. Telemetry

权威事件由状态所有者产生。App 只做有界导出投影。

Trace 必须：

- 对长 identity 使用 hash/长度摘要；
- 不输出完整 Cookie、Mihon/Venera token 或 Base64 payload；
- 高频事件可合并；
- 错误、retry、writer rejection 和生命周期边缘不得丢失；
- 前帧 timing 使用单调时间；
- overlapping 总时长不得与子阶段同时参与 dominant 归因。

Trace 分析属于 audit 证据，不自动成为 Architecture 事实。

## 12. 生命周期与关闭顺序

composition root 创建外部平台能力；`pipeline_runtime` 创建 owned session。关闭顺序遵循依赖逆序：

1. 停止接收新 demand；
2. freeze/close UploadSession；
3. 关闭 DecodeSession 和 cursor；
4. 关闭 DownloadSession writer/transport；
5. 释放 output/frame/texture claim；
6. 关闭 runtime-owned scheduler；
7. App 关闭其创建的平台 facade。

外部注入 capability 不由消费方关闭；owned 对象不得遗漏关闭。

## 13. 静态门禁

静态门禁用于阻止明显的依赖反转、API 泄漏、重复状态和平台反向依赖。它不能替代：

- `flutter analyze`；
- Dart/Flutter tests；
- Rust tests；
- Android debug/release build；
- 真机性能和生命周期验证。
