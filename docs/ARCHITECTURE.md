# zic Architecture

本文件描述当前生产代码的稳定所有权、依赖方向、数据流和生命周期。它不记录版本历史、单轮 Trace 数字、测试通过情况或待办事项。

## 1. 架构目标

- current 具有最高资源优先级，但目标页首帧不得依赖 current 的下载完成或 holder 深度。
- 同一稳定 identity 只有一个权威 request、session、artifact、cursor 和活动 writer。
- Reader 只提交 observation/用户命令并消费只读输出，不直接操作 transport、session、artifact、lane、frame 或 texture。
- 下载、解码、上传使用独立 scheduler；一个层的运行时状态不能成为另一层页面的资格门控。
- 平台能力由 composition root 原子注入；核心包不反向依赖 Widget、Android plugin 或具体 FFI 实现。
- 创建者关闭 owned 对象；外部注入能力不得被消费方误关闭。

## 2. 分层与依赖

```text
Presentation
  apps/app, local_media_ui, reader_runtime, reader
        |
Composition / platform adapters
  pipeline_native, downloads_bridge, storage_bridge,
  local_media_bridge, network_bridge, plugin_host_bridge,
  runtime_bridge, texture_bridge
        |
Policy / resource runtime
  pipeline, pipeline_runtime, downloads, sessions
        |
Domain / contracts
  domain, catalog, resource_cache, transport, storage,
  media, telemetry
        |
Native implementation
  bridge, native/media_core
```

依赖只能向下或指向稳定抽象。底层包不得读取 Widget、路由、App controller 或页面控件状态。

## 3. 包所有权

### `domain`

领域 identity、值对象和不可变实体。不得依赖 UI、插件、网络、缓存、数据库或平台桥。

### `catalog`

漫画源、漫画/章节/page manifest、来源能力和 catalog cache identity。`CachedBrowsableComicSource` 只缓存目录响应；Reader 页面正文仍透传到统一 Pipeline。

### `resource_cache`

封面、详情、搜索、章节元数据等可重新获取响应的唯一缓存平面，拥有容量、TTL、分类预算、in-flight 合并、持久 byte store 和失效策略。

### `transport`

可取消、可分块的 encoded-byte transport、range、validator 和 response 合同。它不拥有 artifact、Reader demand 或播放状态。

### `storage`

partial artifact、连续前缀、校验、seal、原子 promotion、索引和临时 workspace。它不决定页面角色或网络优先级。

### `downloads`

composition-owned `ArtifactCacheManager`、artifact transport/read scheduler、已验证 alias/rekey、章节/整本持久下载与来源 transport 组合。页面 session 状态本身由 `sessions` 拥有。

### `media`

encoded source、cursor、frame、output、renderer 和只读 timing capability。它不选择页面角色或 scheduler 策略。

### `sessions`

`DownloadSession`、`DecodeSession`、`UploadSession`、registry、claim/lease、frame holder、playback timer、Net/Decode/Upload lane 和 `LiveCoordinator`。它是可变媒体状态的权威所有者。

### `pipeline`

把 `ReaderObs` 纯计算为角色窗口和 `DemandPlan`。它定义优先级、水位和 keep 集合，但不创建 transport、artifact、cursor 或 texture。

### `pipeline_runtime`

Reader 章节资源会话的唯一组合所有者。它把 demand reconcile 到 download/decode/upload session，发布 `PipelinePageStream`，管理 frame budget、共享 page download lane、artifact handoff 和短期资源会话 retention。

### `pipeline_native`

把 native source factory、cursor、frame uploader、output projector 和 prewarmer 作为原子 capability 注入 `pipeline_runtime`。核心 Pipeline 不直接创建具体 FFI 或 Android texture 实现。

### `reader_runtime` / `reader`

`reader` 提供 observation、导航和通用 Flutter Reader；`reader_runtime` 负责产品交互、尺寸投影和 `ReaderObs` 适配。二者都不拥有资源 session、缓存或 native handle。

### Home 冷启动组合

`apps/app` 的 Home 关键路径只等待能产生封面的本地库 primary 数据和内置来源。
进程级 native media prewarm 在 Bootstrap/App 呈现后后台运行；持久整本下载队列以
`ready` Future 恢复；已安装外部插件由 `ExternalPluginController.openDeferred` 先完成
manifest 准备，再在后台完成设备扩展发现和 runtime activation。Home 在插件 ready 后
增量替换 source projection，不重新拥有或复制资源缓存。

`HomeLibrarySession` 先发布 entries/SavedComic primary，交给 Flutter 完成一个可注入的
首帧边界，再读取 enrichment 和写入缺失默认值。`ComicCoverCard` 的封面加载失败时，
只有稳定 identity 或 loader 来源改变才允许重试；普通 Widget rebuild 不产生第二套封面
请求权威。首页 artwork 的冷 miss 在 encoded bytes 到达后先返回 memory source，durable
response 写入由 `ResourceCacheManager` 后台排队；同一批封面按卡片独立完成，不等待全部
封面或全部持久化写入。首页 artwork gateway 只用 source-independent raw stable comic
key 探测 response cache；命中时不解析 source、不创建 plugin transport。raw miss 才进入
真实 source loader，且仍写回 raw stable key；当前生产路径不读取 dev.135 的旧
URL-derived/canonical app-update key。来源确认过的 canonical identity 写入
`SavedComicRecord`，只用于插件未激活时的书架只读归并，raw request/chapter identity 不被
改写。未访问的
首页、书架、来源和杂项页由 lazy indexed page 保持未构建，避免隐藏导航页提前创建第二套
封面 loader；访问过的页面状态仍由该页面节点保留。

### 插件与平台桥

- `plugin_host`：信任、权限、请求计划、身份适配和插件生命周期。
- `plugin_host_bridge`：Android 隔离进程与 Mihon/Venera runtime 适配。
- `network_bridge`：浏览器、Cookie/localStorage 快照、challenge 恢复和共享网络能力。
- `bridge`：Dart FFI、native source/cursor/frame ABI 和两个进程常驻 decode isolate。
- `texture_bridge`：Android texture lease、SurfaceProducer、单 lane RGBA blit、schedule 和 release。
- `apps/app`：composition、导航和产品页面；不得定义资源算法。

## 4. Reader 数据流

```text
Reader interaction / viewport / presentation size
  -> ReaderObs
  -> RoleResolver + HeuristicPolicy
  -> DemandPlan diff
  -> PipelineReaderSession / LiveCoordinator
  -> DownloadSession -> DecodeSession -> UploadSession
  -> PipelinePageStream
  -> reader_runtime / Reader presentation
```

Reader 可以提交 stable page、fractional position、目标页覆盖率、阅读方向、viewport/physical target、interaction/zoom，以及 pause/resume/speed/jump 等命令。

Reader 只能消费不可变页面状态、进度、错误和 `PipelinePageSurface`。它不得接触 mutable session、transport、artifact store、scheduler、cursor/frame handle 或 texture registry。

## 5. 页面角色、窗口与优先级

`RoleResolver` 使用以下角色：

- `current`：stable page；
- `last`：刚离开 current 的 keep-only output；
- `transition`：拖动目标页；横向覆盖率达到 0.15，纵向只要真实进入视口即建立；
- `next`、`next2`、`previous`：深度预解码角色；
- `near`、`far`：只保留 encoded download 的邻页；
- `detached`：窗口外。

稳定 encoded window 为前 7、后 3。深度 decode 角色窗口为前 2、后 1；更远页面仍可下载，但不获得动画深水位。

网络优先只由 composition-owned `NetLane` 负责：

- 全局正常并发 5；local bucket 2，remote source bucket 5；
- current priority 1000，保留 1 个高优先级 handoff slot；
- priority 提升原位迁移，差值达到 40 时可抢占低优先级 active task；
- DownloadJob 不读取 holder depth、播放状态或页面控件，不存在第二套网络资格门控。

## 6. Decode 水位与 Transition 首帧

动态页面的 role 最大 holder 深度为：

```text
current / logical next / next2 / previous = 7 / 5 / 3 / 2
```

`transition` 是拖动期间的 logical next，但它在任何 current 深化之前拥有独立首帧：

```text
transition depth 0 -> t>0，目标 1 帧
```

取得首帧后，staged refill 顺序为：

```text
c>2, n>1, m>1, p>1, c>4, n>2, c>6, n>3, m>2, n>4
```

其中阈值是严格水位，实际 batch 可自然越过。高优先级且 `targetWatermark=1` 的 one-frame demand 可与 staged decision 比较优先级，但不得恢复 startup-buffer 或 current-only gate。

静态页由 runtime 分类；一帧即满足。推测静态邻页可在 96 MiB 选择预算内获得 decode/upload，实际 decoded/output 回收仍由 `FrameBudgeter` 权威执行，默认 output budget 为 128 MiB。

## 7. 下载、partial 与 source ingress

普通 response 进入 `DownloadJob` 后先合并 transport 的任意小块：首批约 16 KiB，后续按 64 KiB source-progress quantum 提交到 `DownloadSession`。这与 WebP decode-prefix hint 是两个独立概念：

- local/content/file/asset prefix quantum：1 MiB；
- remote prefix quantum：256 KiB。

`DownloadSession` 保证连续前缀、单 writer、validator/range、seal 和 promotion。已 receiving 且仍有 demand 的传输不会因 observation revision 机械重建；current priority 变化在同一 lane/session 上迁移。

完整 local immutable 或 durable cache response可标记 resident，并经权威 session/source ingress；错误、取消、range response 或长度不一致不得写入完整热字节。

## 8. Animated WebP 生产与播放

```text
transport / artifact stream
  -> DownloadSession ingress
  -> native growing source
  -> demux metadata / NativeCursor
  -> process-lifetime Dart decode isolate
  -> libwebp single-thread frame decode
  -> premultiplied target-canvas RGBA
  -> FrameHolder
  -> UploadSession
  -> Android texture 或 Flutter fallback
```

稳定约束：

- 两个 decode isolate 在进程期常驻；libwebp 帧内单线程；
- 首次 native 请求优先单帧，current 后续请求最多批量返回两帧；
- holder 是 decoded frame 的权威缓冲；可见 output 不计作 successor；
- 缺少 successor 时保持当前 output，等待 producer 通知，不进入 startup-buffer，也不阻塞其他页面 decode；
- playback 使用最近 deadline 的 one-shot wake；静态零时长帧不启动 timer；
- finite animation 到 EOF 保留最后一帧；
- metadata 未完成且 source 增长时允许刷新 demux；未封缄 `needMoreData` 等待 source revision，不用定时销毁 cursor；
- target canvas 使用 contain 和 `height / width`，不裁切、不使用负位移或页面重叠掩盖接缝。

## 9. Upload 与 Android texture

primary upload 角色为 current、transition 和 last；last 只冻结并保留已有 output，不继续 decode。推测静态邻页可在预算内预上传。

Android 路径使用默认 platform MethodChannel、一个串行 blit lane和普通 `mainHandler.post`：

1. retain native frame；
2. 单 lane 复制预乘 RGBA；
3. platform thread 调用 `SurfaceProducer.scheduleFrame()`；
4. 原子替换 output retained frame；
5. 返回 MethodChannel；
6. UploadSession 记录 presentation 并推进 deadline。

已承载页面 output 的 texture lease 在 output 结束时真实释放，不回到 Reader 间复用池。只有从未呈现过的预热 lease 可短期复用，App 非 resumed 时清理 idle prewarm。platform queue、schedule queue/call、blit 和 channel dispatch 必须分别计时。

## 10. Reader 资源会话 retention

Reader Host 从 `PipelineReaderSessionFactory.acquire` 获取资源会话并在退出时 `release`。退出 Reader 不等于立即驱逐整章资源：

- retention pool 最多保留 1 个 idle 章节会话；TTL 为 2 分钟；
- key 包含稳定章节/source revision、loader URI/revision 和 composition 能力指纹；临时 loader 对象 identity 不参与；
- 保留 DownloadRegistry、SourcePool、DecodeRegistry、artifact handoff、media runtime 和 workspace；
- 释放 Reader binding、page projection、playback wake、present claim 和 used texture；
- 不同 key、TTL 到期、容量淘汰或 composition shutdown 时才完整逆序 dispose。

这是一条资源 lease，不是 Reader UI 缓存，也不允许跨 Reader 复用 used SurfaceProducer。

## 11. Identity、缓存与 artifact

不同 identity 层不可混用：catalog identity 定位实体；DownloadId 表示确定字节版本；DecodeId 还包含 epoch、target 和 renderer；presentation identity 只表示页面位置/输出。

缓存分为两个权威平面：

- `ResourceCacheCoordinator.responses`：封面、搜索、详情和章节元数据，使用稳定 namespace/identity/revision、weight、TTL 和 in-flight join；封面使用 raw comic stable identity 和 role，source-level artwork 使用版本化 source identity；
- `ArtifactCacheManager`：Reader 不可变页面 artifact，默认热字节 10 项/256 MiB、alias 上限 8192，并连接持久 backend。

封面 URL/token 不是稳定 comic identity；verified checksum、来源 page key、内容 hash 或用户确认迁移才可注册 artifact alias。App/Reader 不得创建私有图片字节 LRU，也不得让 cache hit 共享 cursor、timer 或 decode identity。

## 12. 插件与网络边界

插件先生成 request plan。GET/HEAD 必须零 body且不得携带实体 headers。普通正文由宿主 transport 流式进入统一 Pipeline；完整 JSON/Base64 RPC 只允许用于明确声明 runtime transform 且有大小上限的兼容路径。

插件和平台桥不得导航、创建 Reader、提交 demand、直接读写 artifact、访问 App controller，或把 Cookie/token/Base64 payload 原文写入 Trace。

## 13. Telemetry 与关闭

状态所有者产生权威事件；App 只做有界导出。长 identity 使用 hash/长度摘要，高频事件可合并，但错误、retry、writer rejection、session retain/reuse 和生命周期边缘不得丢失。overlapping total 不得与子阶段重复参与 dominant 归因。

完整关闭遵循依赖逆序：停止新 demand，关闭 upload/decode/download，释放 frame/output/texture，关闭 runtime scheduler与 workspace，最后由 App 关闭其创建的平台 facade。外部注入 capability 不由消费方关闭。

## 14. 静态门禁

静态门禁阻止明显的依赖反转、API 泄漏、重复权威和文档漂移，但不能替代 `flutter analyze`、Dart/Flutter/Rust tests、Android debug/release build 和真机生命周期/性能验证。
