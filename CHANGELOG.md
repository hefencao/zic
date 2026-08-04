## 0.31.0-dev.115：空 Artifact 自愈与纵向静态 Host 保活

- 修复 durable cache direct-ingress promoted session 被 handoff 读取空临时 artifact，并将 0 字节正文写回 L1/L2 的缓存污染。
- `ArtifactCacheManager` 与 Memory/Persistent backend 拒绝、失效并删除空条目；长度漂移或空 materialize 会逐层失效并自动回源。
- `DownloadJob` 拒绝声明为 0 字节或最终未产生正文的图片响应，禁止空 artifact 进入 promoted 状态。
- 纵向静态页面 current 前后 4 页使用 `AutomaticKeepAliveClientMixin` 保留轻量 host；decoded frame、texture 与 bytes 仍由 Pipeline/FrameBudget 管理。
- Trace analyzer 增加空 artifact 与空 handoff 回写统计；新增 ADR 0099、owner tests 和 dev.115 gate。README/Architecture/Spec 未修改。

## 0.31.0-dev.114：纵向可见页 Demand 与静态输出内存预算

- 纵向 Reader observation 改为按页面与视口的真实交叠投影 current/transition；相邻页一进入视口即建立 demand，不再等待视口中心跨过约 50%。
- 静态页面采用 96 MiB 推测输出预算选择 7/3 窗口内的邻近 decode/upload，每页只解码一帧；128 MiB FrameBudget 仍是实际 output 回收权威。
- 静态纵向 ListView host cache extent 从 2 屏提升到 4 屏，减少轻量页面宿主过早 dispose；纹理和帧仍由 Pipeline/FrameBudget 管理。
- 修复 `PipelineMediaRuntime` 到 `PipelineOutputPrewarmer` 的无继承接口类型错误，改为显式 capability narrowing。
- Trace analyzer 增加 static-warm、无首帧 host dispose 与 frame-budget 回收统计；新增 ADR 0098、owner tests 和 dev.114 gate。README/Architecture/Spec 未修改。

## 0.31.0-dev.113：Texture Pool 与持久 Artifact 直连

- durable persistent/memory cache response 通过权威 DownloadSession 直连 sealed ingress，不再写 Reader 临时 artifact；失败时 reset 回可重试状态。
- ArtifactCacheManager 保留 key+length durability，memory-only session artifact 不会冒充已持久化资源。
- Android texture lease pool 提升到 media runtime factory composition；按 PageAsset 尺寸预热并跨 Reader 重进复用。
- waitingSource 无 source revision 变化时不再被普通 force/ticker 重复提交。
- 新增 owner tests、dev.113 gate、Trace 的 cache-resident 与 texture reuse 统计；README/Architecture/Spec 未修改。

## 0.31.0-dev.112：全局页面下载排序与自适应 WebP 前缀

- 页面传输改为 composition 共享全局 5 槽，按页面唯一 rank 和 local/remote source bucket 调度。
- 跨页退出窗口会取消对应 active/queued task；factory clone 保持同一 lane identity。
- 删除 startup background priority floor，pressure 释放恢复为 current output 已呈现且 `c>4`。
- partial WebP 按 page/frame key 学习 local 1 MiB、remote 256 KiB 的最小 decode prefix；sealed failure 不增加 chunk。
- Trace 增加 ranked download 与 decode-prefix 诊断；README、Architecture、Spec 未修改。

## 0.31.0-dev.111：缓冲解码恢复与启动近邻压力

- startup foreground pressure 只放行 n/m/p 近邻 artifact，far 7/3 demand 保留但延后实际读取。
- pressure 释放提升到 current output 已呈现且 c 水位达到 8。
- DecodeSession failure 保留 FrameHolder；UploadSession 继续消费已解码 successor。
- current/transition 增加最多四次、revision-bound 的有界 decode recovery。
- Trace analyzer 增加 decode recovery attempt 与 buffered depth。
- README、Architecture、Spec 未修改。

## 0.31.0-dev.110：分阶段解码水位与 last output 保留

- 增加 `last`/`next2` 角色；last 不占 previous/next 槽，只冻结并保留既有 output。
- 引入 staged c/n/m/p refill；transition 作为逻辑 n，batch 可自然越过阈值。
- DecodeSession 每产出一帧即唤醒 upload，首帧呈现不等待整批 refill。
- 串行化同一页面的 presentation，先发布首 Surface，再追到最新 pending frame。
- current→last 取消 active upload 并冻结，last→current/transition 恢复；frame budget 保护 last output。
- Trace 增加 `decodeRefill` 与 `lastFrameKept`；更新 owner tests 与静态门禁。
- README/Architecture/Spec 未修改。

## 0.31.0-dev.109：Cache tier 内聚与 Android native build identity

- 将 encoded-byte L1、LRU、in-flight join、tier lookup 和 write-through 内聚进 `ArtifactCacheManager`；backend 只保留 open/store。
- 删除独立 byte-cache 文件、过渡 cache interfaces、backend readArtifact 旁路及对应旧门禁。
- 删除独立 `NativeBlitter.configure` JNI；Rust `blit` 内部按 geometry mismatch 配置，并在 lock failure 后只重试一次。
- 增加 source native build ID、JNI symbol gate 与 Gradle preBuild 验证，禁止旧 `.so` 静默进入 APK。
- telemetry 使用 `surfaceReconfigureCount`；旧 configure/retry 字段仅由 analyzer 兼容读取。
- README/Architecture/Spec 未修改。

## 0.31.0-dev.108：统一 Reader artifact cache 与 Android texture geometry

- 新增 composition `ArtifactCacheManager`，统一 Reader page artifact 的 memory→backend lookup、读取可见性/backend 持久存在性、精确长度、并发读取合并、LRU与写穿。
- Memory/Persistent chapter service 改为可替换 `ArtifactCacheBackend`，删除各 backend presence capability、独立 read pool 及 transport/handoff 的重复分派；persistent cache read 直接按 durable index/path 打开，不再 materialize DownloadSession。
- transport、handoff、presentation bytes loader 和快速重进共享同一个 manager；普通 response cache 保持独立。
- Reader dispose 改用 lane-level `cancelAll()` 清除 active/pending task，避免 registry snapshot 遗漏 queued key。
- Android native texture 在首次、resize、Surface 重建或一次 lock failure 后配置 `ANativeWindow` geometry；lock status 4 只重试一次，禁止每帧配置。
- Trace 增加 configure/retry 与 blit-lock/fallback 汇总；新增 ADR 0092、dev.108 audit、owner tests 和 ownership gate；README/Architecture/Spec 未修改。

## 0.31.0-dev.107：Reader 重进清理与 progressive artifact handoff

- persistent cache handoff 在读取临时 promoted artifact 前按 identity 与长度探测持久副本；命中时跳过重复 materialize/store。
- current/transition encoded bytes 从单个 whole-body chunk 改为受 foreground pressure 和 lease-through-stream 保护的 1 MiB progressive startup segments。
- Reader dispose 先 detach handoff listener，并记录 coordinator、handoff、media、downloads、workspace 分阶段耗时。
- 修复 nullable `ArtifactCacheReadScheduler` Trace projection 的编译错误。
- 新增 ADR 0091、dev.107 audit、owner tests、Trace analyzer 扩展与静态 ownership gate；README/Architecture/Spec 未修改。

## 0.31.0-dev.106：启动前景背压与整块 artifact ingress

- current/transition 的 promoted encoded bytes 改为单个 immutable body 注入 Reader DownloadSession，避免 1 MiB Dart stream 循环重复唤醒。
- 前景 artifact scheduler lease 保持到 response body 被真正消费，不再在整文件 materialize 后提前释放。
- Reader 在首次 demand 提交前建立 composition 级 foreground pressure；首帧已呈现且 successor 水位达到 2（或确认静态/结束）后释放。
- background 仍保留 1 MiB chunk quantum；下载 7/3、预解码 2/1、lane 5/3/2 未改变。
- Trace 新增 delivery mode 与 foreground pressure hold 统计；新增 ADR 0090、dev.106 audit、owner tests 和静态门禁。

## 0.31.0-dev.105：直接 promoted artifact 读取与 encoded-byte 热缓存

- persistent cache 命中不再调用 `DownloadSession.restore()` 执行 metadata/prefix sniff、SQLite cache sync 和状态通知；只恢复 artifact 元数据并直接读取 promoted file。
- 大于 1 MiB 的 promoted file 参考 VibeVenera，在 isolate 中执行整文件同步读取；current/transition 使用快速路径，background 继续 1 MiB chunk quantum。
- 新增 composition-shared encoded-byte LRU：默认 4 项/96 MiB、并发读取合并、快速 Reader 重进复用；不拥有 demand/decode/upload 状态。
- 快速读取失败回退同一 artifact stream，不错误转向 origin；Trace 增加 read mode、memory hit/join、materialize 和 hot-cache 容量。
- 新增 ADR 0089、dev.105 audit、owner tests 与静态 ownership gate；稳定 README/Architecture/Spec 未修改。

## 0.31.0-dev.104：分块 Artifact 调度与 retained cursor 连续性

- persistent artifact scheduler 从整条 stream lease 改为 chunk quantum；foreground 连续读取，foreground 压力期 background 同时最多占一个槽。
- background 每个 chunk 重新读取权威 demand priority，晋升 current/transition 不取消、不重开同一 artifact stream。
- `sourceRead` 增加 scheduler acquire 次数、最大等待和 foreground acquire 数，便于验证启动拥堵。
- `DecodeSession.detach()` 在保留 frame 时继续原 cursor，修复角色回切后重复上传 frame 0、需要切走再切回才播放。
- 新增 owner-package 回归、ADR 0088、dev.104 三清单与 ownership gate；7/3、2/1、current/transition、5/3/2 不变。

## 0.31.0-dev.103：Reader 重进与 platform presentation 确认修复

- `SystemClock` 改为进程级 monotonic epoch，增加 Reader session create/dispose 生命周期 Trace，修复跨 session 导出时间轴不可比。
- Android texture MethodChannel 改用 background task queue；两个 output-stable blit lane 取代单一全局 lane，`scheduleFrame` 使用 main queue 前部执行。
- playback timer 对 platform acknowledgement 最多抵扣一个名义帧周期，避免 MethodChannel 回包延迟逐帧拉长动画。
- decode/upload role 晋升间隔改记为 predecode lead，不再误报 upload backpressure；旧独立时钟 Trace 的 source concurrency 仅按 session 报告。
- 修正 `platformOther` 重叠计算，不再从 platform upload 重复扣除外部 blit-lane queue。
- 新增 ADR 0087、dev.103 三清单、Kotlin background task queue stub 和 ownership gate；既定 7/3、2/1、current/transition、5/3/2 不变。

## 0.31.0-dev.102：异步 texture schedule 与共享 artifact 读取调度

- 修复三项 Source Browser quarantine 向 `testWidgets(skip:)` 传入字符串导致的测试编译错误，改为布尔 skip、稳定 ID 注释和登记门禁。
- 修复 promoted artifact cold-open、Reader session dispose 与 native runtime prewarm 的弱类型 Future 错误链。
- Android texture 移除 blit lane 的 main-thread latch；retain/blit/replace 完成后异步投递 schedule，并在同一 platform-thread runnable 中回复。
- 新增 composition-shared persistent artifact read scheduler：总槽 5、background 最多 4、current/transition 保留槽；pending priority 动态跟随 Pipeline plan，晋升不取消流。
- `sourceRead` 增加 scheduler wait 与取得槽位时 priority，Trace analyzer 增加跨 Reader 最大读取并发。
- 新增 scheduler 单元测试、ADR 0086、dev.102 三清单和 ownership gate；既定 7/3、2/1、current/transition、5/3/2 不变。

## 0.31.0-dev.101：恢复文档职责并拆分 Android schedule timing

- 重写 README、Architecture、Spec、Implementation Plan、Implementation Status 和 Handoff，删除稳定文档中的逐轮 dev 堆叠、Trace 数字和验证结果。
- 新增 `DOCUMENTATION_POLICY.md` 与 repository gate，禁止版本历史、单轮推断和完成记录重新污染稳定文档。
- quarantine 从版本绑定的 `dev.100` marker 迁移为稳定 `Q-001` 至 `Q-003` ID；删除版本耦合的 dev.100 聚合门禁。
- 历史 feature gate 不再绑定当前 App build 或要求当前 Handoff 引用历史 audit。
- Android texture 将旧 `platformScheduleMicros` 拆为 platform-thread queue 和实际 `scheduleFrame()` call；旧 Trace 由 analyzer 标记为 legacy combined timing。
- 分析新设备 Trace：前帧主导仍集中在旧 combined platform schedule、native decode 和 channel dispatch；1 MiB promoted artifact stream 仍存在 1–3 秒尾部，保持为未关闭问题。

## 0.31.0-dev.100：测试隔离治理与 Android texture schedule/reply 修复

- 修复 `library_ui_test.dart` 未限定 key、`misc_settings_test.dart` 缺 scheduler import 的测试编译闭包。
- 删除重复/过时测试：App adaptive classifier、`RasterPlan.isRenderUpscaled`、以 filter quality 证明 codec resize 的断言。
- 修正 Reader download callback 条件、remote metadata persistence 和 refresh in-flight 测试。
- 三个 Whole-App Source Browser 时序测试登记为 dev.100 quarantine；匿名 skip 由静态门禁拒绝。
- Android present 等待 platform thread 实际执行 `scheduleFrame` 后，从 blit lane 直接 reply，避免第二次 main-thread result runnable。
- 启动时预热 1×1 Android texture lease；lease 立即释放。
- timing 拆出 `decodedLeadMicros` 与 `uploadBackpressureMicros`，analyzer 对 dev.99 旧 trace 按前帧 deadline 归一化 dominant stage。

## 0.31.0-dev.99：前帧端到端耗时与本地 artifact 1 MiB ingress

- 新增不合并的 `framePipelineTiming`：覆盖 worker ready/queue、isolate、native decode/metadata、decode/upload lane、source wait、output prepare、Android texture 原子子阶段、`platformOther` 和 fallback。
- 每次 output 激活仅记录前 12 个不同 frame 的首次 presentation；后续只记录 >=250 ms 端到端、>=100 ms present/单阶段、deadline miss 或错误。
- 增加 `tool/analyze_frame_pipeline_trace.py`，直接汇总 dominant stage、p50/p95/max、逐帧启动样本、sourceRead 与 taskFailed lane 时序；总 platform upload 不再与子阶段重复竞争 dominant。
- promoted artifact 本地流式读取由 256 KiB 修复为 1 MiB；普通网络 chunk 不变。
- 修复 refresh in-flight 发布竞态、章节打开未持久化已读、tiny WebP renderer filter 投影，以及错误报告中多个过时/脆弱测试假设；删除仅被旧测试引用的 `comicDetailsRetryKey`。
- 新增 ADR 0083、dev.99 三清单和 ownership gate。

## 0.31.0-dev.98：锁定 libwebp 离线归档与精确补丁准备链

- 从文件库取得并保留 `libwebp-1.6.0.zip`，锁定归档 SHA-256 与干净 `vp8_dec.c` SHA-256；默认构建不再依赖网络。
- `fetch_webp.sh` 将归档解压到 tool-owned immutable upstream cache；发现缓存漂移时自动从锁定归档重建。显式 `ZIC_WEBP_SOURCE` 必须匹配干净源哈希，避免旧补丁树进入 prepared 阶段。
- VP8 TLS patch 由文件库真实源码重新生成；`prepare_webp.sh` 统一 LF，先用 `patch --dry-run --fuzz=0` 验证全部 hunk，再实际应用并运行结构 verifier，杜绝 partial patch 被 token grep 误判为成功。
- 删除无生产调用且已证明脆弱的 `apply_libwebp_vp8_tls_patch.py`；host/Android source build 在归档可用时不再强制依赖 git。
- 新增 ADR 0082、dev.98 三清单、真实归档准备/缓存修复/修改源拒绝回归，并实际完成 host libwebp 静态构建与 Animated WebP smoke。

## 0.31.0-dev.97：Reader 50% 无缝播放交接与诊断 Trace 压缩

- `ReaderView.onPageChanged` 不再发出整数 targetless observation；stable page 改变时保留真实 fractional position，outgoing page 继续是 transition，避免 `demand-detached` 退休有效 texture。
- `ViewportResolver` 默认 50% 交接；新 stable/current 在 midpoint 接管播放，旧 transition 暂停，无 40%–60% 双冻结区。
- Pipeline runtime 在异步 UploadSession snapshot 后重投影既有 viewport，修复新页偶发不启动、回切才播放。
- Debug Trace 对高频 frame/decode/upload/scroll 事件作固定首事件窗口摘要，保留 count、首尾、min/max；错误与权威生命周期不合并。超长本地 identity 输出稳定 hash+长度。
- 修复 `ArtifactCacheStreamStore`、`FrameDecodeTiming`、`ExpectedLengthEncodedSource` 三处 Dart interface promotion 编译闭包。
- libwebp prepared tree 当时改用函数锚点 transformer；该机制已由 dev.98 的锁定归档、源哈希与精确 patch dry-run 取代。
- 新增 ADR 0081、dev.97 三清单、midpoint/Trace/CRLF patch 回归与静态门禁。

## 0.31.0-dev.96：常驻双 isolate 与单线程本地 WebP 播放

- 两个 Dart native decode isolate 由 App composition 在 `runApp` 前显式等待预热完成并进程期常驻；页面/cursor 不再关闭 worker pool。
- current 使用独立高优先级队列并保留一个 worker 槽，非 current 最多占用其余一个槽。
- transition→current 的 same-key decode/upload 改为等待 active 完成后 follow，避免丢弃有效帧和反复退休纹理。
- current watermark 从 1 提升为 2，保留两个 successor；既定 7/3、2/1、current/transition 和 5/3/2 不变。
- libwebp 锁定 1.6.0；新增自动 prepared-tree 补丁链，复用 VP8 TLS workspace；帧内线程固定为 0，明确拒绝额外 8 线程 worker interface。
- native WebP 改用预乘 `MODE_rgbA`，target canvas 使用预乘 source-over；Android 只逐行复制且不每帧设置 Surface geometry，Flutter fallback 删除二次预乘。
- source 增长且 metadata 未完成时主动刷新 demux；小于 8 px 的 contain target 不再放大；本地文件/DocumentFile 分块提升为 1 MiB。
- 新增 ADR 0080、dev.96 三清单审计、Dart/Rust 回归规格和 dev.96 静态门禁。

## 0.31.0-dev.95：直通缓存/native ingress 并改用目标画布 WebP

- 根据高性能设备 Trace 排除硬件瓶颈：native decode 中位约 70.7 ms、Android blit 中位低于 1 ms，但首帧仍约 1.7–2.3 秒，platform callback 最高约 1.59 秒。
- 对照 VibeVenera 通用媒体链，确认 ZIC 仍在缓存命中时整页物化 `Uint8List`、并发重复读取 promoted artifact、逐块同步写临时 artifact，并在 Dart/native 边界执行双重复制。
- 新增 `ArtifactCacheStreamStore`；持久缓存以范围流直接进入同一个 DownloadSession，流式 store 禁止 `PromotedArtifactReadPool` 再次整页 prime。
- `Artifact` 改用 `IOSink` 缓冲写，pause/seal/promote 时统一 flush；DownloadSession 只建立一份 owned chunk，并增加 native ingress 与 artifact write 聚合 timing。
- native media ABI 升至 6，增加 expected-capacity、reserve、commit；Dart 直接写入 native source 预留内存，兼容 `zic_source_append` 仅保留为旧调用 helper。
- WebP demux 仅在下一 descriptor 不可用且增长达到 512 KiB 或 source seal 时刷新；不因每个 source revision 重解析完整文件。
- ANMF rectangle 使用共享 start/end endpoint 映射，libwebp 直接缩放 fragment 到目标 rectangle，再在最终 target canvas blend/dispose；删除 source-size canvas 与每帧完整纯 Rust 缩放。
- 新增 promoted stream、artifact exact range、native reserve/commit header、相邻/奇数 rectangle 无缝映射测试，以及 ADR 0079、dev.95 审计和门禁。

## 0.31.0-dev.94：迁移常驻 WebP 解码 worker 与持久 demux

- 根据设备 Trace 定位：动画 `decodeMicros` 中位约 124.9 ms；Android native blit 约 5.6 ms，但 platform round trip 中位约 770 ms、最大约 1.69 s，主要等待发生在 Dart/MethodChannel 调度。
- 只读参考 VibeVenera 的通用 WebP pipeline，在 `bridge` 增加两个常驻 decode Isolate；帧解码不再同步阻塞 UI isolate。
- isolate 消息只传 native cursor/frame 地址、epoch 和小型状态，不复制像素或完整 WebP 字节。
- `media_core` 缓存 demux frame descriptors；只有 source 长度或 seal 状态变化才重新 demux，不再逐帧解析完整文件。
- demux descriptor 只保存 authoritative source 中的 offset/length，不再保留第二份完整压缩字节快照。
- dev.94 当时使用 advanced decoder config 帧内多线程；该历史设置已由 dev.96 的单线程 frame decode 取代。删除逐帧 full-canvas clone 的改动仍保留。
- `frameDecoded` Trace 增加 `nativeDecodeMicros` 与 `decodeDispatchMicros`，区分 native codec 与 isolate/queue 往返。
- 新增 demux reuse/rewind Rust fixture、C threaded decode smoke、ADR 0078、dev.94 三清单审计和静态所有权门禁。

## 0.31.0-dev.93：预解码动画后继帧并修复媒体测试闭包

- 修复 `upload_session_test` 的 cursor fixture 未绑定 `LoopCursor`，导致完整静态元数据未进入 UploadSession。
- 当时更新 Reader viewport 测试：50/50 覆盖属于 overlap；该历史合同已由 dev.97 的 stable/current midpoint 接管语义取代。
- 更新 LiveCoordinator source revision 测试：source seal 是独立权威 revision，应被 drain 一次。
- 修复本地媒体 viewport 测试对 transformed child 尺寸和 fitWidth 第二层 FittedBox 的过时假设。
- 动画当前 output 不再计入未来 prepared depth；DecodeSession 可在当前帧显示期间保留一个 decoded successor。
- UploadSession 在 deadline 前不提前替换 output，deadline 到达后优先消费已缓冲 successor；没有 successor 时保留旧 output 等待。
- Android texture telemetry 增加 MethodChannel 总往返和扣除 native queue/upload 后的 bridge 等待。
- Android `content://` seekable descriptor 通过 `/proc/self/fd` 直接分块读取，避免每 256 KiB 一次 MethodChannel 往返；不可 seek provider 保留原流式 fallback。
- 新增 ADR 0077、dev.93 三清单审计和静态门禁。

## 0.31.0-dev.92：修复静态/有限动画播放输出生命周期

- 根据用户实际回切复现 Trace 纠正 dev.91 结论：6 次页面挂载仅 3 次首帧；3 个已呈现帧的时长均为 0，却仍产生 `playbackFrameDue`，之后在空缓冲上反复 `decoding -> ended`。
- `PlaybackTimer` 对零/负时长保持 idle；已确认的静态帧不进入动画推进。
- 动画帧到期不再先删除当前 output，而是保留旧帧并将 `preparedDepth` 投影为 0；successor 上传成功后原子替换。有限动画到 EOF 时保留最后一帧并记录 `playbackCompleted`。
- 修复错误报告中的 `Stream.toList(growable:)` 测试编译错误；修正 native texture viewport 测试的根节点 tight-constraint fixture，不改变产品几何。
- 新增静态零时长、有限动画最终帧、零时长 PlaybackTimer 回归、ADR 0076、dev.92 三清单审计和所有权门禁。既定 7/3、2/1、current/transition、5/3/2 与 256 KiB I/O 不变。

## 0.31.0-dev.91：修复页面回切无限加载并补齐本地媒体 Trace

- 根据设备 Trace 定位：upload 消费 decoded frame 后，页面离开 current/transition 会退休 output，但仍在前 2/后 1 decode window 的 DecodeSession 不 detach，空 holder 对应 cursor 停在 EOF；回页反复 `decoding -> ended` 并永久 `waitingFrame`。
- UploadSession 在 demand detach 与 frame-budget trim 两条 output 回收路径中统一通知 DecodeSession；仅 holder 为空时标记 cursor 重建。LiveCoordinator 只在 retained decode 实际重置后提交 follow-up，upload 遇到 missing frame 也会唤醒现有 decode demand。
- 动画正常 frame advance 不重启 cursor；不保留整章 texture、不新增 Reader/App bytes/ImageProvider cache，7/3、2/1、current/transition 与 5/3/2 保持不变。
- 新增 `sourceRead` 聚合 Trace，区分 persistent artifact、session artifact、本地 file、Android document、插件资源与远程来源，并记录 open、首块、总流时长、块数、块尺寸和最大块间停顿。
- `frameDecoded/frameUploaded/framePresented/playbackFrameDue/pageOutputReleased` 增加解码、上传、呈现、播放迟到和 output 生命周期字段；高频 chunk 只聚合，不逐块写事件。
- 新增静态图页面离开再返回回归、UploadSession 输出退休回归、缓存/来源读取 Trace、playback lateness 测试、ADR 0075、dev.91 三清单审计和所有权门禁。

## 0.31.0-dev.90：修复 Mihon runtime 编译闭包与漫画身份别名

- 将 `NetworkBrowserSnapshotStore` 移入 `network_bridge/android/src/runtime/kotlin`；该 source set 同时进入 network AAR 与 `generateMihonAbiAssets` 的隔离 Kotlin 编译，并加入 Mihon runtime 完整性检查和 release keep 规则。
- 根据设备 Trace 定位同一 Mihon source 下 439/440 长度的两个漫画 identity：一个持久 342 章，另一个反复返回 1 章，且均非 synthetic。根因为 `comicId` 编码了可变 SManga 标题、简介和 memo。
- 新增 source-owned `CanonicalComicIdentitySource`；Mihon/Venera adapter 只用规范化作品 URL 比较同源别名，原始 opaque identity 继续作为唯一请求 locator，禁止把 canonical key 传回插件。
- canonical alias 合并与最优目录选择归 `catalog`；首页、书架和更新投影只显示一个漫画，优先保留真实章节更完整的 locator。详情和下载状态通过注入的 identity matcher 接受同源别名。
- App composition 按 canonical alias 检查目录回归；曾有多个真实章节时，空目录、synthetic-only 或单章节结果均不得覆盖。Trace 增加 requested/effective ID 长度、alias 数量和脱敏 canonical identity hash。
- 删除仅被旧门禁和文档引用的 `resolveComicDetailsRoute` 兼容 facade，并把 source identity/catalog 回归逻辑拆入 `demo_home_catalog_identity.dart`。
- 新增 ADR 0074、dev.90 三清单审计、catalog/plugin-host 回归和 dev.90 所有权门禁；Reader/Pipeline 策略未改变。

## 0.31.0-dev.89：稳定来源 Cookie 会话与章节目录

- 可见 WebView 使用来源运行时声明的精确 User-Agent；Mihon `AndroidCookieJar` 与 Venera runtime 通过共享 `AndroidBrowserCookieSession` 导入同站点、同 User-Agent 的原子 Cookie 快照。
- 保持主进程浏览器与插件隔离进程独立 WebView data directory，避免 Android 多进程目录锁冲突和数据损坏；共享的是有界会话快照，不是 WebView 私有数据库。
- 修复详情初始化刷新和下拉刷新并发时“章节已更新但显示红叉”；成功/失败结果图标 2 秒后自动消失，插件设置改为与 WebView、迁移一致的 IconButton。
- Mihon synthetic revision 升至 3；runtime 记忆已观察到的真实目录，App 持久层拒绝用空目录或 synthetic-only 结果覆盖真实目录，并收紧 `UnsupportedOperationException` 的能力缺失判定。
- 新增来源浏览、验证恢复、浏览器会话、详情刷新和目录回归 Trace；Cookie 仅记录名称与数量，禁止输出值。
- 新增 ADR 0073、dev.89 三清单审计和所有权门禁；Reader/Pipeline 的 7/3、2/1、current/transition、5/3/2、256 KiB 传输及本地 artifact 所有权未改变。

## 0.31.0-dev.88：修复来源验证闭环并完善详情交互

- 修复 Dart 3.12 无关 capability interface 不提升、两个 `Stream.toList(growable:)` 测试错误和 `reader_runtime` 测试缺少 `ContentKind` 依赖的编译闭包。
- `network_bridge.openBrowser` 改为等待可见浏览器 Activity 关闭；插件隔离进程在任何 WebView/CookieManager 使用前设置独立 data-directory suffix，避免主进程 WebView 打开即退出。
- Cloudflare interceptor 取消不可交互的后台 WebView和 30 秒等待，challenge fail-fast 投影为 typed verification；Mihon host 默认调用窗口为 45 秒、Android IPC envelope 为 65 秒，普通 timeout 不伪装成验证错误。
- 来源页和详情页在用户返回后才失效缓存并自动重试；历史 synthetic 单章以 revision 2 失效，目录失败或 timeout 不再退化为单章节。
- 详情右上角固定为地球 WebView、迁移、插件来源设置；加入书架后的本地详情继续保留来源能力。下拉刷新使用持续的刷新/绿勾/红叉状态图标。
- 来源分类和标签支持点击进入当前来源搜索，长按进入多选并复制；当前未建立聚合搜索或第二套搜索缓存。刷新、来源 action 和标签选择按 Presentation 交互所有权拆入 `comic_details_interactions.dart`，避免继续增长超大详情文件。
- 新增 ADR 0072、dev.88 三清单审计和所有权门禁；Reader/Pipeline 的 7/3、2/1、current/transition、5/3/2 与 256 KiB 传输未改变。

## 0.31.0-dev.87：统一来源验证回退并优化本地大图恢复

- 修复 `PluginHostBridgePlugin.kt` 缺少 `android.os.Bundle` 导入的 Android 编译闭包。
- Mihon runtime 将 cause 链中的 Cloudflare challenge 统一投影为 `sourceVerificationRequired`；来源首页、分页、封面、详情和章节/下载操作均提供同一 WebView 恢复动作，普通网络/解码错误不会误触发验证。
- 新增 `ComicWebUriSource` 能力，Mihon/Venera opaque identity 只在 plugin adapter 中解析；详情页右上角改为访问作品网页，下拉刷新仍是唯一刷新入口。
- 来源分类、来源标签和书架分类分区显示并过滤重复作者；自适应模型升至 v5，补充 long strip/vertical comic/scroll comic/长条漫画等条漫证据，纠正被来源切片后误判 LTR 的作品。
- 根据设备 trace，promoted artifact 恢复改为优先验证原子 metadata 与文件长度并单次读取；缺失/失配仍完整重算 CRC。默认完整校验 API 与 Pipeline/DownloadSession 权威边界保持不变。
- 使用文件库中的 libwebp 1.6.0 源码完成 host 增量/循环 fixture 检查；新增 dev.87 owner gate、回归测试、ADR 0071 与审计。

## 0.31.0-dev.86：修复详情 WebView 编译闭包并拆分共享网络桥

- 补齐 `ComicDetailsSourceWebViewOpener = Future<void> Function()`，一次修复 `comic_details.dart` 与 `source_browser.dart` 的四处类型未定义编译错误。
- 新增 `network_bridge` workspace/Flutter package，统一拥有来源 WebView、Cookie/localStorage 快照和 Android 平台网络辅助能力；App composition 直接调用稳定 facade；插件控制器不再转发通用 WebView/Cookie 命令。
- 将 `MihonLoginActivity`、登录快照存储、Cloudflare interceptor、Android CookieJar 与 fallback DNS 从 `plugin_host_bridge` 迁出；删除旧 `openMihonLogin`/`readExternalLoginSnapshot` MethodChannel API 和实现。
- Mihon 1.4/1.6 `NetworkHelper` 继续保留兼容包名，但改为消费 `dev.zic.network` 共享实现。共享类加入 parent-first、运行时完整性校验与 consumer ProGuard keep 规则。
- `plugin_host_bridge` 只保留插件信任、APK/脚本隔离、ABI shim、请求路由和生命周期；通用浏览器/Cookie/Cloudflare 不再由插件桥拥有。
- 浏览器 Activity 的进程名改为 manifest placeholder，由 App composition 显式选择；登录 snapshot 改为原子文件交换，避免跨进程 SharedPreferences 缓存导致读不到最新 Cookie/localStorage。
- 新增 network owner Dart 测试、Kotlin 提取编译、dev.86 静态门禁和 ADR 0070；更新全仓 analyzer/test runner、依赖白名单和文档。
- 未新增 rhttp 依赖，未改变章节目录判定、256 KiB 数据块、GET/HEAD 零 body、Pipeline 7/3、2/1、current/transition 或 5/3/2 lane。

## 0.31.0-dev.85：修复 Cloudflare 章节目录并流式读取本地大图

- 应用 staged 覆盖后继续收口：Mihon 章节目录调用失败不再创建 synthetic “正文”章节；只有目录能力不存在且 gallery 正文预检非空时才允许兼容单章。
- 详情首屏目录失败显示权威错误、重试和 WebView 图标；dev.85 当时由 App composition 注入 `openMihonLogin`，该临时入口已在 dev.86 迁到 `network_bridge.openBrowser`；Presentation 不访问 Cookie、runtime 或 session。
- 旧 synthetic 章节只在权威真实目录恢复后由 composition 协调淘汰；opaque Mihon identity 解析保留在 `plugin_host` 协议适配层。
- Mihon runtime 增加共享 Android CookieManager 的 Cloudflare WebView interceptor，覆盖 403/503、`cloudflare`/`cloudflare-nginx` 与 30 秒 challenge 等待；GET/HEAD 零 body 契约不变。
- transport、artifact 与下载 fallback 默认块由 64 KiB 提升到 256 KiB；source progress/Trace 的 64 KiB 聚合语义保持不变。
- 普通本地文件使用 `RandomAccessFile` 直接分块；Android `content://` 使用 bridge v4 的 `openDocument/readDocumentChunk/closeDocument` 句柄、range/validator 和取消关闭，不再通过单个完整 `Uint8List` 作为 Reader 常规输入。
- 新增 owner package 测试、Mihon 章节/ABI 契约、dev.85 静态所有权门禁、ADR 0069 与三清单审计。

## 0.31.0-dev.84：修复 Mihon 静态转译、章节目录与详情元数据

- 修复 JMComic/18comic 静态 WebP：按扩展 source client 的自定义网络能力选择 runtime transform，普通 Mihon 图片仍使用宿主流式 transport；transform 版本进入 chapter source revision，淘汰旧未转译 artifact。
- `SMangaUpdate.chapters` 非空时成为权威目录，删除组合更新后的重复 chapter-list 请求。
- 翻译并持久化 Mihon source name、description 与 genres/tags；详情页隐藏数字 identity、统一下载整本图标、增加“继续”药丸和可展开单行 tags。
- 章节行先按 chapter token、再按同 source/comic 的唯一 source revision 复用已持久化 page list，不重新预取全部章节正文。
- 修正 DecodeTarget 错误放大测试，并将 completed artifact 进度回归迁移为纯 snapshot projection。
- 新增 ADR 0068 与 dev.84 所有权门禁。

## 0.31.0-dev.83：恢复稳定预下载、每漫画自适应与物理像素拼接
- 普通来源方向、manifest `animatedHint` 与 `.webp` 后缀不再预填自适应结果；动画分类只接受 metadata 或两份实际运行时动画能力。

- 修复 `LiveCoordinator` 漏导入 `DecodeSnapshot/DecodeState/UploadState` 的 kernel snapshot 编译闭包。
- 删除按 `venera-resource` scheme 选择预取 profile 的分支；所有 Reader 统一 current+前7+后3 下载、current+前2+后1 预解码、current/transition 上传和 5/3/2 lane。
- 迁移 VibeVenera 可移植的 per-comic adaptive model v4：metadata、封面排除、两份几何/实际动画证据、0.60/0.80 confidence 与持久化 fingerprint；普通来源方向不再冒充 adaptive 事实。
- 本地 `.webp` 后缀不再直接写入动画 hint；GIF 保留固有动画 hint，WebP 由 metadata/header/runtime 证明。
- 连续 Reader page extent 按 DPR 落到同一物理像素栅格；stitched texture 直接填充权威 page box，移除普通滚动时每页独立 FittedBox/ClipRect/RepaintBoundary 边缘。
- 删除生产无调用的 `ReaderPipelineProfile.standard/sourceStreaming` 兼容别名。
- 新增 policy plan、adaptive classifier、metadata 持久化、physical boundary 与 texture direct-fill 的确定性 owner 测试和 ADR 0067。

## 0.31.0-dev.82：修复动画源网格合成、帧消费推进与 Trace 风暴

- Animated WebP 不再独立缩放每个 ANMF 子矩形；blend/dispose 在源 canvas 上完成，再统一缩放完整帧，修复纵向页面内部水平条带错位。
- frame timer 消费当前输出后独立补充 decode watermark，动画不再等待下一次网络 chunk；下载完成后仍可继续逐帧播放。
- source 增长按 64 KiB、seal、failure 边界唤醒 decoder；无实际 holder/output 变化时不记录或提交 decode/upload 工作。
- `bytesCommitted` 在 `DownloadSession` 按 64 KiB 聚合并在终态刷新；raw Trace 默认上限从 20000 降为 10000，避免短时间内导出巨大文件。
- 修复 controlled transport 测试在暂停 `StreamIterator` 时等待 `StreamController.close()` 的关闭死锁；纵向几何 double 断言改用容差。
- 新增 ADR 0066、dev.82 三清单审计、source-grid 合成单测与动画帧消费回归。窗口、lane 与所有权边界不变。

## 0.31.0-dev.81：修复 Mihon 宿主流式传输、动画上传竞态与章节即时入场

- Mihon `resolveResource` 只返回最终 URL/headers/GET request plan；宿主 transport 直接流入 `DownloadSession`，source-owned 完整字节 RPC 仅在直连及刷新计划均失败后兼容回退。
- `DownloadSession` 持有每次网络 run 的 `networkStartLength`，未知总长度在 committed bytes 增长后立即显示 receiving，而不是直到 seal 前都显示连接中。
- `UploadSession` 串行化同一 `DecodeId` 的平台 upload，并在 queued/active 操作排空后才 release slot；被 supersede 的结果或 `Failure(texture)` 不再写入新 revision，修复快速翻页后动画停滞。
- 章节入口改为 route-first：先 push Reader loading shell，再在 route 内加载 chapter、检查 artifact 与组合 response loader。
- 普通图、完整 WebP 与 Pipeline texture 的 Presentation 对齐统一为居中，不建立 WebP 特例。
- 删除 downloads/App 封面测试中的真实 loopback socket、30 秒 timeout、Reader `pumpAndSettle`、lazy child 数量、魔法 offset 和静态门禁强制的 400ms 等待；改为 controlled Stream/Future、注入单调时钟与纯 `ReaderVerticalGeometry` owner 测试。
- 修复 `FlutterActivity` 上不可用的 `registerForActivityResult` 编译错误，Android Trace 导出继续使用系统文档创建 Intent。

## 0.31.0-dev.80：修复增量流式唤醒、统一等比栅格与 Android Trace 导出

- `IngressSnap` 增加单调 source revision；Decode lane 按 `DecodeId` 排空活跃任务期间到达的增长/seal revision，并去重同 key 的后续任务，避免首个 partial decode 后直到下载完成才再次尝试。
- 未知 Content-Length 的传输投影按 committed bytes 区分 connecting/receiving，不伪造百分比；接收态公开实际新增字节。
- 新增 `AlignedRasterSize` 作为普通图片、DecodeTarget 与 native WebP 共用的 contain + 原比例 + 8 像素物理栅格契约；Dart/Rust 使用相同整数比较和 fixture。
- `MediaAspectViewport` 成为唯一 Presentation fit 决策。尺寸未知时不再落入 `BoxFit.fill`；header/static 原图尺寸也不会被对齐后的 output buffer 尺寸覆盖。WebP prefix 读取按 committed length 排空，避免同步期间的新 chunk 被吞。
- Debug Trace Android 文件导出改由 App 注入的 SAF `CreateDocument` 能力完成，不再调用未实现的 `file_selector.getSavePath()`；复制独立限制为 64 KiB UTF-8 JSONL，并报告截断或平台错误。
- 新增 source revision drain、统一 raster、未知尺寸 fit、transfer phase、raw copy/export 与 dev.80 静态门禁；+7/-3、+2/-1、current/transition 和 5/3/2 不变。

## 0.31.0-dev.79：恢复插件、封面与 Reader 流式稳定性

- Venera JavaScript source operation 改为单 in-flight；Mihon 保留配置并发。删除 WebView 内 60 秒 raw `comic.loadInfo` promise/object cache，详情缓存只由 `resource_cache/catalog` 持有。
- App 不再只把 HTTP(S) 视为 source-owned 封面。`mihon:resource:`、当前 Venera locator 等 absolute scheme 均进入 `ComicSourceResourceGateway`；`ResourceCacheManager` 合并完整 encoded-image resolution，避免同 key 重复 durable lookup 和回源。
- DownloadSession 在 source ready、每个增量 chunk、seal 和 source failure 时通知同一 lifecycle listener；listener 晚接入 ready source 会立即收到当前 snapshot。Decode lane 因此可在 `needMoreData` 后继续，并能在最终 seal 时完成解析。
- `DecodeSession` 将 ingress/source 和 cursor 异常保存为权威 failure；LiveCoordinator 唤醒 Upload，页面 output 显示失败，不再永久停留 loading。空 holder 的 demand 重入继续按稳定 identity 重建 cursor。
- 连续阅读未知页面 extent 不再依赖 mutable currentIndex；异步尺寸更新只在 idle 时保持顶部可见页的像素偏移，用户拖动/惯性滚动不会被 anchor jump 竞争。
- 运行时/header 确认 Animated WebP 后，自适应布局以 `runtime-animation` 高置信度覆盖 source vertical hint；显式漫画级方向覆盖仍优先。
- 新增 Venera/Mihon 并发、custom locator 封面、encoded cache 合并、source growth/seal/failure、decode failure output、稳定纵向 extent 和动画方向回归及 dev.79 静态门禁。
- 未缩小 +7/-3 下载、+2/-1 预解码、current/transition 上传或 5/3/2 lane。

## 0.31.0-dev.78：修复 Reader 等比输出、页面重入与原始 Trace 导出

- 补齐 `RendererKind` 显式 domain 导入；`UploadRegistry` 不再越权读取 `PlaybackState`，改用 `UploadSession.playbackRunning`。
- native WebP 将 decode target 解释为最大边界，按源 canvas 等比缩小且不强制放大；上传和 Android texture 使用实际 frame 尺寸，消除纵向压缩/拉伸。
- WebP 页面移出 demand 且 holder 为空后，再次进入会重建 cursor 并恢复首帧；不通过永久保留纹理或每次 EOF rewind 制造无限循环。
- 删除详情页自动遍历所有章节正文的页数预检，未知页数保持待加载；目标 manifest 写入后不再同步全库 reload，已读持久化也从进入 Reader 的同步路径移除。
- Debug Trace 拆分 UI projection 与最多 20000 条的 raw export ring；复制/文件导出使用原始事件，导出 capability 可测试并显示平台保存失败。
- 新增 fitted decode/upload、detach replay、章节不预取正文、raw trace copy/export 与 dev.78 所有权门禁。+7/-3、+2/-1、current/transition、5/3/2 未改变。

## 0.31.0-dev.77：Pipeline 媒体运行时原子迁移

- 新增原子 `PipelineMediaRuntimeFactory`/`PipelineMediaRuntime`，一次绑定 source、cursor、uploader、opaque output projector 与 renderer；每个 Reader session 创建并按依赖顺序关闭一个 runtime。
- 新增独立 `pipeline_native` composition package。`pipeline_runtime` 不依赖 `bridge`/`texture_bridge`，App 通过 `NativePipelineMediaRuntimeFactory` 注入平台实现。
- `PipelineReaderSession` 正式接通生产 `DecodeRegistry`、`UploadRegistry`、FrameBudgeter 与 LiveCoordinator；保持 +7/-3 下载、+2/-1 预解码、current/transition 上传和 5/3/2 lane。
- 删除 `PipelinePageStream.source`/`EncodedSource` Presentation 泄漏；Reader 页面改为消费只读 `PipelinePageOutputStream` 和不暴露 `DecodeId`、textureId/native handle 的 `PipelinePageSurface`。
- Reader WebP 不再由 `NativeWebpPlayer` 创建 cursor/texture。App 的媒体 Pipeline 演示同步迁移到 `LocalImagePlayer + PipelinePageOutputStream`，未保留测试专用旧参数。
- 暂停/倍速命令进入 Pipeline session，UploadRegistry 原子保存并向新旧 UploadSession 投影同一配置；用户 pause 与 viewport freeze 独立，异步 present 完成后读取最新 speed，避免旧命令覆盖或误唤醒 transition 页。
- Android uploader 按 `DecodeId` 复用 texture；identity 退休后等待最后一个 output claim/frame owner 释放再销毁 lease，session close 排空已退休 texture，避免长章节累积或旧 surface 使用已释放 texture。
- output replacement/清空先切换 snapshot，并在下一 Flutter frame 释放旧 claim；`LocalImagePlayer` 也只在 opaque surface 真正进入 widget tree 后报告首帧，避免 use-after-release 与过早 ready telemetry。
- playback ticker 只在至少一个 UploadSession timer 处于 running 时运行；静态页和全部 viewport-frozen 输出不再维持无效 60Hz 轮询，present/resume 会重新唤醒。
- 新增 runtime close、upload claim/retirement、composition smoke 与 dev.77 静态边界门禁；使用用户提供的 libwebp 1.6.0 源码完成 host build、增量解码和 loop fixtures 验证。
- 非 WebP 完整 artifact 的现有 Flutter Presentation 路径未在本轮伪装为已迁移；后续统一必须单独设计，且不得恢复第二条 Reader WebP decode 链。

## 0.31.0-dev.76：Reader 页面加载所有权与立即退出审计

- 删除 `ReaderView` 的 viewport 固定居中加载 overlay、`_readyPageKeys` 和由首帧回调驱动的父级 setState；Reader 不再保存第二份页面 ready 权威状态。
- 删除 `LocalImagePlayer.showLoadingIndicator` 兼容开关。静态图、GIF、WebP 的 loading/ready/invalid 继续由实际页面媒体呈现，纵向连续布局只出现随图片区域移动的加载反馈。
- 首帧回调继续由 `_ReaderPageHost` 去重并记录 `firstFrameReady` telemetry，但不再控制全屏视觉状态。
- 审计设备 trace：Reader 立即退出时 7 个 demand 均 detach，未出现 exception、退出后继续接收字节或 session 泄漏证据；当前页 WebP 首帧仍需在有 Flutter/Android 环境复验。
- 全仓检查其他 `CircularProgressIndicator`：Reader 控制栏只保留下载按钮工作态和 Pipeline 进度投影；封面、详情、仓库与路由初始化圈均属于其局部操作/内容 owner，没有第二个 Reader 固定居中 overlay。
- 新增 owner-package Widget 回归、Reader 禁止全局加载圈回归、静态所有权门禁和 ADR 0060。未改变下载/解码/上传窗口、lane、GET/HEAD、插件或缓存策略。
- 耦合审查另记录基线既有债务：`PipelinePageStream.source` 仍向 `NativeWebpPlayer` 暴露 encoded source，Presentation 仍创建 native cursor/texture。仓库尚缺 production `FrameUploader` 与只读 output 投影，因此本轮不做会形成双链或破坏播放的半迁移；后续必须原子收回 `pipeline_runtime`。

## 0.31.0-dev.75：编译闭包、契约归属与后续迭代提示词

- 修复 `home_widgets.dart` 将 `Future<Uint8List>` 返回给 `EncodedResourceSource` loader 的类型错误，并删除只被测试使用的 `ComicDetailsScreen` 兼容包装；详情测试直接覆盖真实 `LocalComicDetailsScreen` owner。
- 将 `AssetBundleTransport` 测试从 App 移到 `pipeline_runtime`，删除 App/Reader 对该内部 transport 的无用转出文件。
- 显式导入 Reader preference extension 和 domain-owned `ComicManifest`；不通过扩大 package export 掩盖调用方漏导入。
- 删除 App WebP 测试中重复的 `readerPageDownloadId` 契约，canonical download identity 继续由 `downloads` package 自己测试。
- 修复 Pipeline 测试对非 const `Coverage` 的 const 调用。
- 新增 dev.75 编译与所有权迁移门禁，并将仓库门禁更新到测试实际所有者。
- 修复 CI/本地验证覆盖缺口：`pipeline_runtime`、`reader_runtime`、`local_media_ui` 现在进入 `flutter analyze` 与 `flutter test` 主循环；为此前没有 test 目录的 `local_media_ui` 增加 package composition 编译 smoke test；`check.sh` 不再违反 `AGENTS.md` 自动执行 `dart format`。
- 新增 `docs/AI_ITERATION_PROMPT.md`，集中记录 Architecture、耦合审查、被否决退化方案、测试和交付约束。
- 未改变 Pipeline 的 7/3 下载、2/1 预解码、current/transition 上传、5/3/2 lane 或现有网络/缓存行为。

## 0.31.0-dev.74：稳定纵向几何、封面文件缓存与可用 Debug Trace

- 修复 `local_media_ui.dart` 在声明之后放置 `part` 指令导致的 Dart 编译失败，并新增全仓 Dart library 指令顺序门禁。
- 修复运行时媒体尺寸使用 `width / height` 而 Reader 连续布局要求 `height / width` 的单位倒置；删除拼接页的负 1 像素平移，不再用重叠掩盖错误几何。
- 连续 Reader 改用带 `itemExtentBuilder` 的可定位列表，并在首次 attach 前按保存页设置初始 offset。恢复第 87 页不再先挂载 0 到目标页，尺寸变化继续使用视口锚点而不是回跳。
- 来源浏览和详情封面统一消费 `EncodedResourceSource`/`FileImage`，不再把持久缓存重新读成 `Uint8List`/`MemoryImage`；封面 identity 不再混入章节 revision，成功封面也不会因列表 reload token 重建请求。
- 封面缓存升级为 `artwork-v2`，旧的无效响应自动旁路；新响应在写入前验证常见图片容器，HTML/错误页不会污染七天持久缓存。
- Debug Trace 增加 JSONL 导出、关键词/会话/级别过滤和严重度强调色；连续高频 mount/dispose/observation/demand 仅在 UI 投影中合并，失败事件完整保留。
- Trace 同时摘要 Mihon manga/chapter/resource opaque token，避免 identity 占据整份日志。
- 新增纵向恢复不挂载长前缀、封面文件恢复、无效封面不缓存、trace burst 合并及诊断 UI 回归。

## 0.31.0-dev.73：Pipeline 构造闭包与 Presentation 依赖收口

- 修复 dev.72 拆分后遗漏的 Dart 编译闭包：`ArtifactCacheStore`、`ContentKind`、`ReaderPipelineProfile`、`readerPageDownloadId`、`IngressSnap.source`、`NativeSourceFactory` 与 `_reportPageDimensions` 均改为正确的所有者接口或显式依赖。
- `PipelineReaderSessionFactory` 现在必须接收 `SourceFactory`；`pipeline_runtime` 不再依赖 FFI `bridge`，Native source 由 `local_media_ui` 的平台组合常量注入。
- 新增 factory 的不可变派生接口，页面本地 loader、artifact cache 和测试 byte loader 在保留 source factory 的前提下组合，禁止 Presentation 自行创建下载或解码所有者。
- `local_media_ui` 不再引用 `ArtifactCacheStore` 或调用 `readerPageDownloadId`；页面下载 identity 直接读取只读 `PipelinePageStream.identity`。
- `PipelinePageStreamSnapshot` 使用 Pipeline 自有 `PipelinePageContentKind`，不向 Reader/媒体 UI 泄露 transport `ContentKind`；encoded source 从权威 session ingress 投影，不再读取不存在的 `IngressSnap.source`。
- 恢复并帧后合并页面尺寸回报，只更新连续布局的只读比例投影，不创建下载、解码或重排命令。
- 新增 `test_pipeline_runtime_compile_boundary.py`，覆盖 SourceFactory 注入、包依赖闭包、只读 identity/content projection 与尺寸回调边界。
- dev.70/72 的前 7/后 3 下载、前 2/后 1 预解码、current/transition 上传、5/3/2 lane、共享 request-plan 与流式进度逻辑保持不变。

## 0.31.0-dev.72：Pipeline 运行时所有权与共享请求方案复用

- 新增独立 `pipeline_runtime` 包，集中持有 Reader 会话的 `DownloadRegistry`、`LiveCoordinator`、`SourcePool`、artifact workspace、network/decode/upload lane、进度 publisher 与生命周期。
- `ReaderRuntimeScreen` 不再创建、销毁或直接引用下载/解码/上传/session/storage/transport 所有者；它只提交 `ReaderObs`，消费 `PipelinePageStream`、页面字节投影和当前页进度投影。
- 当前页传输进度选择迁入 `PipelineReaderSession.accept(ReaderObs)`，删除 Reader 对 page transfer selection 的第二条控制路径。
- 本地图片/WebP presentation 不再接触 `DownloadSession` 或 `DownloadSnapshot`，仅观察 Pipeline 提供的只读 encoded-byte stream。
- 首页、来源浏览、详情页与迁移对比的远程封面统一通过 `ComicSourceResourceGateway` 和共享 source transport/cache；不再各自调用插件完整 `loadResource`。
- Venera HTTP artwork 优先解析 `comic.onThumbnailLoad`，仅无 thumbnail hook 时兼容回退 `onImageLoad`；章节 durable locator 继续使用 `onImageLoad`。同 locator request plan 在 JavaScript runtime 与宿主 transport 中并发合并并有界缓存。
- 保持 dev.70 的前 7/后 3 下载、前 2/后 1 预解码、current/transition 上传和 5/3/2 lane；没有通过削减预下载或并发处理上行流量。
- 新增 Pipeline ownership、封面共享 request-plan、Venera thumbnail resolver 和 Reader 无底层所有权静态/回归门禁。

## 0.31.0-dev.71：来源资源原子绑定与组合层解耦

- 修复 `demo_home_source_compat.dart` 通过 `ChapterDownloadService` 静态类型直接调用 `setChapterResourceLoader`/`setChapterResourceTransport` 的编译错误；无继承关系的能力接口全部显式绑定。
- 新增 `ChapterResourceAccess` 与 `ConfigurableChapterResourceAccess`，将 complete-byte fallback 与 streaming `ByteResponse` transport 作为一个不可分割的组合值一次性注入。持久下载内部只读取同一 `_resourceAccess` 快照，避免运行中的下载观察到半更新配置。
- 新增 `ComicSourceResourceGateway`：统一负责 sourceId 解析、旧 Venera runtime locator 拒绝、`ExternalPluginResourceTransportPool` 生命周期、Reader response loader 与章节下载绑定。`_DemoHomeState` 不再直接持有 transport pool 或调用下载服务的资源 setter。
- gateway 关闭时先解除其绑定的下载服务，再关闭 transport pool；外部注入且晚于 Home 存活的下载服务不会继续保留指向已关闭 gateway 的回调。
- 将章节页面读取、单章下载和整本下载动作收回 `_DemoHomeState` 的专用 extension，删除“把整个 State 传给全局 helper”访问私有下载/会话字段的隐式耦合。
- 保留旧 loader/transport capability 作为第三方与测试服务兼容面；生产 `PersistentChapterDownloadService` 使用原子 capability。新增原子流式优先、gateway 关闭解绑和 legacy locator 前置拒绝回归及静态门禁。

## 0.31.0-dev.70：VibeVenera 风格流式来源管线与稳定进度

- 以 dev.69 为唯一基线，对照用户上传的 VibeVenera `Streaming Image Pipeline Architecture`、共享下载流、稳定预取窗口和进度 publisher，撤销“Venera 只请求当前页”的退化。
- 新增 `ComicResourceRequest` 能力边界：插件只解析图片 URL、method、headers、body 与变换需求；普通图片正文由共享 host transport 直接流入既有 `DownloadSession -> Artifact -> Ingress`，不再等待完整 `Uint8List` 或经插件 RPC 搬运整图。
- Venera 稳定窗口恢复为前向 7 页、后向 3 页下载；前向 2 页、后向 1 页可预解码；只有当前/过渡页上传。network/decode/upload lane 分别为 5/3/2，JavaScript request-plan runtime 仍串行，避免全局 request context 串号。
- GET/HEAD 在 JS 和 Dart transport 两层强制无 body/实体 headers；同 locator 的并发 request-plan 解析共享进行中的 Future。来源 `onLoadFailed` 只生成替代 request plan，不再迫使普通图片回退到完整 RPC body。
- 章节持久下载优先使用 streaming `ByteResponse`，每个 chunk 更新 authoritative session；80ms 合并投影真实已收字节和页内进度。下载管理在首个 chunk 后退出“连接中”不定进度，完成页不再重现网络态。
- Reader 当前页进度独立为 `ReaderDownloadProgressPublisher`：立即同步页切换、只显示 queued/receiving，sealed/promoted/restore 均隐藏，避免已完成页面切换时进度条闪烁。
- 流响应支持 subscription cancel/discard；错误响应不再为重试完整读取正文。普通窗口 detach 仍保留已经 receiving 的连接，显式取消/关闭才终止，遵循 VibeVenera 的 detach-not-eviction 规则。
- Debug trace 对 Venera resource/comic/chapter 的 Base64 locator 使用 hash+长度摘要，identity 与嵌套 payload 均不再打印完整 token。
- Pipeline demand 去重与 viewport/playback 更新解耦：相同 role window 不重复提交下载/解码，但拖动覆盖率仍逐 observation 更新呈现；同 sourceId 的新 wrapper 也不会关闭旧 Reader 正在使用的活动 transport。
- 新增 GET 零上传、首 chunk 早于完整 body、显式 discard、runtime transform fallback、`onLoadFailed` 替代计划、章节 chunk 进度、完成 artifact 不闪烁、7/3 下载与 2/1 预解码分层回归。

## 0.31.0-dev.69：Venera 原生二进制、请求取消与稳定连续锚点

- 对 dev.65–68 做差异审计并记录未闭环项：durable locator 到 dev.68 已进入真实日志，但普通图片正文仍经 JavaScript/Base64 桥；原生连接在 demand 解除后继续到超时；尺寸更新会调用当前页同步；纵向测试仍直接读取未构建 lazy separator。
- 普通 Venera 图片使用 `http_binary` 原生快路：JavaScript 只接收一次性 token，图片字节由 Android 原生响应直接回到 runtime packet；仅当来源声明 `onResponse`/`modifyImage` 时保留兼容的 JS 字节路径。
- GET/HEAD 强制清空 body 与实体 headers，Venera 默认并发降为 1、Reader deferred window 降为仅当前页；Pipeline 对完全相同的 role window 不再增加 revision 或重复提交 demand。
- requestId 进入每个 Venera bridge HTTP 调用；cancel 会立即 disconnect `HttpURLConnection` 或 cancel fallback call，JS finally 显式释放 request-scoped 状态。页面关闭后不再让已解除 demand 的网络工作继续到超时。
- 每漫画纵向拼接改为继承/启用/停用三态。旧 `verticalStitch:false` 迁移为继承，避免仅设置方向时暗中关闭全局拼接。
- 连续 Reader 在尺寸或 viewport 改变时保存可视中心的页面内锚点，重排后恢复；拖动/滚动期间不执行恢复或当前页同步。拼接模式无 separator，并对后续页面做 1 logical-pixel 覆盖以封闭物理像素舍入接缝。
- 页面内部 loading spinner 在 Reader 中关闭，改为 viewport 级唯一加载指示；未知当前页至少占满 viewport，真实尺寸到达后无裁切重排。
- 修复 `reader_navigation_test.dart` 原第 309 行：先导航并等待第二页进入 lazy list，再通过已构建 element 读取 gap；新增媒体尺寸、视口锚点、偏好迁移、pipeline 去重与 Venera 原生二进制/取消门禁。

## 0.31.0-dev.68：Venera 入口预检、请求止损与无缝连续布局

- 修复远程详情以 `refreshRemote: false` 打开已存在章节时绕过旧 Venera locator 迁移的问题。只要章节含 `venera-resource://token`，Reader/单章下载/整本下载入口都强制刷新章节元数据；刷新后仍为旧 token 时在进入 pipeline 前失败。
- App source-resource composition 与 Venera runtime adapter 增加独立止损门：旧 token 在插件 runtime 调用前被拒绝，避免遗漏入口再次产生确定性失败请求。
- Venera deferred resource Reader profile 收窄为当前页加一张前向编码页，把单次 download demand 上限降为 2，并关闭 Reader 层自动网络重试；相同 URI 仍只共享进行中的读取，完成字节继续归既有 session/artifact 所有。
- 纵向拼接模式不再创建零高度 separator，而是使用完全相邻的 builder children；非拼接模式才创建 8px 间距。未知活动页至少占满一个 viewport，使加载指示保持在可视区域中心；拼接呈现使用 `fitWidth` 对齐页面宽度，真实尺寸到达后按完整图片比例重排，不裁切也不拉伸。
- 新增旧 locator UI 刷新、runtime 调用前拒绝、保守 demand window、无 separator 拼接和 viewport loading placeholder 回归及静态契约。

## 0.31.0-dev.67：Reader 控制所有权收口与组合解耦

- 修复 `demo_home_source_compat.dart` 对无继承关系能力接口的交叉类型提升编译错误；旧 Venera locator 刷新现在显式绑定 `RefreshableChapterComicSource`。
- 删除顶部 Reader 中与底部 Slider、手势和每漫画设置重复的页码、上一页/下一页、选页菜单与布局切换；顶部只保留返回、章节标题、可选只读页面副标题、传输进度和本漫画设置。
- 删除 `ReaderAppBarActionsBuilder`/`appBarActionsBuilder` 以及任意 Widget 标题注入，改为窄化的纯字符串 `pageSubtitleBuilder`；本地文件 Reader 不再直接持有 `ReaderController` 或调用 `requestPage`。
- 将 `ReaderSessionSettings`、自适应 profile 与分类函数从 `reader_runtime_screen.dart` 拆到独立模型文件；runtime screen 重新低于 1500 行，并增加结构门禁防止重复控制 API 回流。
- 纵向跳页在目标页面完成懒构建、进入目标视口并发布 observation 后才确认命令；测试按稳定语义 key 等待目标页，不再假设固定两次 pump 足够。
- 移除本地文件 Reader 已废弃的页码/前后翻页/选页公开 key 和兼容别名，更新 UI/Reader 契约回归。

## 0.31.0-dev.66：Venera 代际刷新、请求合并与实测连续布局

- 修复 dev.65 自描述 Venera locator 的作用域错误：资源恢复函数显式接收当前来源对象，不再引用仅存在于 operation 局部作用域的 `source`。
- 章节元数据缓存引入 durable-locator schema revision；打开、单章下载和整本下载遇到持久化的 `venera-resource://token` 时，先通过刷新能力绕过旧章节元数据并从来源刷新，避免不可恢复 token 被 Reader 反复重试。
- Venera runtime 按 locator 记忆已解析的 `onImageLoad` 配置并合并同一运行时的并发解析；Dart source adapter 只在请求进行期间合并相同资源读取。完成后的页面字节仍由 Reader/download artifact 所有者管理，不新增长期页面缓存。
- 纵向连续 Reader 不再用整屏高度猜测未知页面。静态图片从同一份已取得字节读取 PNG/JPEG/GIF/BMP/ICO 头，WebP 复用既有容器解析尺寸，再按真实比例重排；不创建第二条 `ImageStream`，不裁切漫画内容。
- Reader 方向切换、页码跳转和上一页/下一页命令会等待新滚动容器 attach 且具备 content dimensions 后再执行和确认，修复布局切换后顶部控制栏失效。
- 新增旧 Venera locator 刷新、章节缓存代际、并发资源合并、实测媒体几何、连续列表跳页及顶部控制栏跨布局回归。

## 0.31.0-dev.65：持久 Venera 资源、每漫画自适应与连续 Reader

- 修复 `MihonRuntimeDriver.kt` 使用 `Locale.US` 但未导入 `java.util.Locale` 的 Android 编译阻断。
- Venera 章节页面改用版本化、自描述且仅允许 deferred image identity 的 `venera-resource:` locator；运行时 token 表丢失后仍可重新执行来源 `onImageLoad`。旧 `venera-resource://token` 仅保留读取兼容。
- `DebugTraceLog` 的 enabled/record/clear 通知按帧合并，禁止在 Reader Widget build 中同步 dirty `AnimatedBuilder`。
- 新增全局自适应布局和纵向拼接设置，以及按 `sourceId + comicId` 持久化的每漫画方向、拼接和自适应覆盖。
- 自适应布局参考 VibeVenera 的“全局开关 + 每漫画覆盖 + 置信度门槛”，但只使用当前领域已有的来源方向、页面几何和动画提示；不创建模型或直接输出 pipeline demand。
- Reader 纵向模式改为按页面比例的连续 `ListView`；拼接只移除页间距，不合并页面/artifact identity。RTL slider 的 Directionality、端点标签与页面顺序保持一致。

## 0.31.0-dev.64：杂项页、分层设置与编译闭环

- 修复 ChapterDownloadService 能力接口绑定与 Map 下标测试编译错误。
- 新增第四页“杂项”，包含快捷设置、设置、关于与 Debug trace。
- 设置页按数据、网络、书架、阅读、下载、外观分层；数据备份和统一缓存维护可执行。
- 主题、书架默认值、Reader 默认模式/沉浸行为和整本下载策略持久化或复用现有持久队列。

## 0.31.0-dev.63：插件资源传输、媒体识别与章节元数据渐进收口

- 严格以用户上传的 `zic_v0.31.0-dev.62_source-management-tabs-mihon-chapter-preflight.zip` 为唯一代码基线；`mihon-main` 与 `vibevenera-master` 仅用于兼容行为对照，未修改、未并入产品源码。
- `ImportedChapterRecord` 只要求稳定 `pageId` 唯一，不再把可重复的资源 URI 当作页面主键。同一图片地址可在章节中出现多次，而下载、进度与 Reader identity 仍由不同 `pageId` 区分。
- `PersistentChapterDownloadService` 新增可注入的 source-resource loader，并在 `downloads` 内为 `mihon:`/`venera-resource:` 等来源私有 URI 选择 `LoaderTransport`。App composition 只绑定当前 source registry，不在详情页或按钮中复制下载分流。
- Reader transfer progress 改为按帧合并、在 build 结束后发布，避免 `ValueListenableBuilder` 构建期间被同步 `DownloadSession` snapshot 再次标脏。
- Venera 章节页根据原始资源名提供 WebP/GIF/PNG/JPEG/AVIF 提示，本地媒体名也补齐常见格式识别；提示只用于快速选择，实际字节嗅探和 codec 仍是最终裁决。
- Venera native HTTP 默认继承受限 WebView 浏览器 UA，并改为最多 8 跳的宿主管理重定向：逐跳接收 Cookie、支持相对 `Location`、跨 origin 清理 Cookie/Authorization，URLConnection 与 DNS fallback 均禁用内部自动重定向。
- Mihon 封面被归一化为保留来源 headers 的 `mihon:resource:`；相对与 protocol-relative thumbnail 可通过统一 source loader 显示。页面资源同时携带媒体类型提示。
- Mihon 详情中的未知页数当时以最多两个并发 worker 渐进预检并复用 `CachedBrowsableComicSource`；该普通章节正文预检已由 dev.78 / ADR 0062 撤销，synthetic gallery 的非空正文验证仍保留。
- Mihon 目录调用失败或为空时不再立即终止：只有 synthetic 章节真实解析出非空页面才接受 gallery 兜底；目录与页面均失败时保留原始目录失败为 suppressed 诊断。
- 新增重复资源 URI、插件私有持久下载、当时的 Mihon 页数预检、Venera WebP/UA/重定向及 Mihon gallery/封面契约回归；普通章节页数预检后由 dev.78 替代。

## 0.31.0-dev.62：漫画源分类、插件页签与 Mihon 章节结果闭环

- 漫画源管理中的启用来源按“原生 / Mihon / Venera”分区，并以分隔线隔开；Mihon 同一插件 family 的语言来源只显示当前语言或通用语言，其余语言在该页面默认折叠。折叠不改变安装记录、来源 identity、启用状态或信任粒度。
- Mihon/Venera 各自的管理页移除左右双栏，顶部仅保留“已安装 / 仓库”切换，内容区随页签整页切换。设备上的 Mihon 扩展迁入“已安装”页，使用独立刷新按钮与错误状态，不再和仓库加载共用 busy/error 区域。
- 保留来源启用顺序：原生与 Venera 在各自分区内可拖动，Mihon 以语言 family 为单位拖动，折叠的语言来源随 family 一起移动。
- Mihon 章节探测同时兼容 public/inherited 方法以及 Future、RxJava 1 `toBlocking().value/single/first`、RxJava 2/3 `blockingGet/blockingFirst/blockingSingle`。真实目录探测出现错误时不再被空候选掩盖为 synthetic 单章节。
- 空目录 gallery 兜底在详情阶段先实际解析页面；只有能得到非空页面列表才暴露 synthetic “正文”，并写入真实页数。普通远程章节的未知页数显示为“页数待加载”，不再误导为 0 页。
- 新增/更新漫画源信息架构、Mihon reactive adapter、空目录 page preflight 和折叠位置回归门禁。

## 0.31.0-dev.61：Reader/WebP 组合解耦与兼容插件双栏管理

- 修复 `apps/app/lib/reader_runtime.dart` 直接引用未导入 `SourcePool` 的编译错误。Reader session、transport、workspace、pipeline 与 streaming source 的装配迁入新 `packages/reader_runtime`；App 文件缩为兼容导出，生产依赖不再直接声明 `pipeline/sessions/storage/transport`。
- 修复 WebP 流式探测对 `parseWebpPrefixInfo` 与 `webpPrefixDeclaresAnimation` 的遗漏。两者由 `media` 包显式提供，WebP UI 不再依赖偶然的转出。
- 将超过 3300 行的 `webp_demo.dart` 迁入 `packages/local_media_ui`，按模型与预览、catalog/codec、静态图片播放器、页面、native WebP 播放器拆分；App 保留两行兼容 facade，单个实现文件均低于 1600 行。
- 漫画源管理首页只保留 Mihon/Venera 入口。每个生态自己的管理页改为固定双栏：左侧仅显示该生态已安装插件及启动失败/移除状态，右侧显示设备导入与仓库安装/更新。
- Mihon 仓库按包名中的插件 family 聚合多语言变体。当前界面语言优先作为默认可见项，其次 `all/multi`、英语；其余语言放入默认折叠的“其他语言”区域，不再把同一插件的所有语言版本平铺。
- 架构门禁改为读取新 package 实现而非 App facade，并新增 App 生产依赖泄漏、文件规模、双栏布局和 Mihon 语言折叠回归。

## 0.31.0-dev.60：Venera 登录、Mihon 章节探测与 Reader 流式闭环

- 严格沿用 dev.59 代码线；`vibevenera-master` 仅作为 Venera 账号和流式进度交互参考，没有替换 ZIC 的 runtime、下载、缓存或 Reader 所有权。
- Mihon 组合详情接口返回空章节时不再立即生成“正文”。runtime 会继续对详情对象与原始漫画对象探测独立章节目录，并依次兼容 `getChapterList`/`fetchChapterList`；空结果或明确的 unsupported 只表示继续探测，只有最终规范化目录为空才生成单章节兜底。真实章节仍保留 live `SChapter` 和稳定 wire identity。
- Venera `account` 现映射为统一来源账号协议：账号密码、按源声明顺序传递的 Cookie 字段、WebView 登录快照、退出登录和登录状态。网页登录回传最终 URL、标题、Cookie 与 localStorage；隔离 runtime 仍拥有持久化与来源回调，Presentation 只承担用户交互。
- App bootstrap 立即挂载内存 composition 与主界面，持久书架/缓存/下载服务在后台打开；恢复期间只显示顶部 2px 同步条，不再用“正在恢复书架”阻塞可操作界面。
- Reader 默认缩放比例下不创建会竞争横向手势的 `InteractiveViewer`，远程分页重新由 `PageView` 接管；只有显式缩放后才进入单页拖动/缩放。静态 PNG/JPEG/静态 WebP 不显示暂停与播放速度，动画能力由媒体探测或页面提示决定。
- 远程 WebP 直接绑定权威 `DownloadSession.ingress.source` 的增量 native cursor；`needMoreData` 等待 session committed bytes 推进而不是回退到完整文件。顶部控制栏分别显示恢复时已有前缀和本次网络新增进度，下载完成后仍沿既有 artifact/promote 生命周期收口。
- 修复 runtime worker 回归夹具只调用四个旧操作的问题：测试现在实际往返 settings 与 account 操作，再验证完整 operation 集合，不通过缩短期望绕过协议缺口。
- 新增 Mihon 章节探测、Venera 账号/login snapshot、Reader 手势/静态控制、WebP 增量 source 与双进度条的源码提取式门禁；Venera 账号加载与设置失败相互隔离，设置回调失败不会隐藏登录入口。

## 0.31.0-dev.59：Mihon 章节目录身份与 Venera 插件设置闭环

- 严格以用户上传的 `zic_v0.31.0-dev.58_fixed.zip` 为唯一基线。未合并此前 dev.58 归档或其他历史候选。
- Mihon 详情页保留插件返回的完整多章节目录，不再由单章节兼容路径覆盖。仅当真实章节列表为空时生成一个带显式 `synthetic` 标记的“正文”章节；非空目录不会调用 synthetic factory。
- Mihon runtime 在详情加载后按 opaque chapter ID 保存原始 `SChapter` 对象，阅读时优先复用，避免重建丢失扩展私有/运行期状态。runtime 重启或缓存缺失时重新拉取来源目录，并按 URL，或名称、章节号、汉化组和发布时间组合精确匹配；缺失和歧义均明确失败。
- 1.4 与 1.6 兼容 `HttpSource.fetchChapterList` 均重新执行扩展的 `prepareNewChapter(chapter, manga)`，确保多章节 URL、编号和来源自定义归一化在进入 ZIC 协议前完成。
- Venera runtime 新增 `loadSourceSettings`/`updateSourceSetting` 完整实现，映射 `switch`、`text/input`、`select`、`multiSelect` 与 `callback/action`；设置值使用类型保持的私有持久化，兼容 dev.58 的字符串布尔/数组旧值。
- 漫画源管理页现在为 Mihon 与 Venera 的 `ConfigurableComicSource` 都显示设置入口。Venera 不显示 Mihon Web 登录项；动作设置在用户显式点击期间可执行来源确认对话框中的非取消回调，并在页面反馈执行结果。
- 新增多章节不降级、章节稳定身份、双 ABI `prepareNewChapter`、Venera 官方形态设置枚举/持久化/动作回调、通用 adapter action kind 与依赖门禁回归。

## 0.31.0-dev.58：Mihon 分版本 ABI 隔离与 Venera 运行语义闭环

- Mihon 1.4 与 1.6 `extensions-lib` 不再进入 App runtime classpath。Gradle 在构建时分别解析上游固定 revision、提取 `classes.jar`、使用 Android D8 生成 dex asset，并写入长度/SHA-256 manifest；1.5 metadata 显式映射到兼容的 1.6 asset。
- activation 按 `extensionLib` 选择 ABI，并把扩展 APK 与对应 ABI jar 交给 child-first `MihonExtensionClassLoader`。`eu.kanade.tachiyomi.*` 只从插件 workspace 加载；AndroidX Preference 与 OkHttp/Injekt/协程等 common runtime 仍由隔离宿主进程单一提供并合并资源，修复旧 e-hentai 扩展覆盖 1.6 final `HttpSource` 方法的 verifier 失败。
- 两份动态代码文件都按 Android 14 要求在写入前标为只读、写后 `fsync`、长度/SHA-256 重验并原子提升。activation 分别预检 child plugin ABI 与 parent common runtime，不再把 API 版本冲突误报为入口构造失败。
- Venera 不再把宿主 bootstrap 的 strict directive 强加给来源脚本，并提供兼容的全局 `res` scratch binding；详情加载错误现在携带 operation 与受限 JS stack，便于定位真实源脚本。
- Venera 默认调用上限从 10 秒调整为 55 秒，为底层单次 15 秒连接 + 30 秒读取预算保留 10 秒桥接/脚本收尾余量，且仍低于 60 秒平台上限；超时会继续协作取消，并显示操作名与实际上限。
- 新增 Mihon ABI 路由/child-first、Gradle 双 ABI 资产闭包与故障注入、Venera legacy `res` 详情及 55 秒默认限制回归。

## 0.31.0-dev.57：只读 Mihon dex 与 Venera 分页/资源兼容闭环

- 修复 Android 14+ 拒绝从可写 APK 加载 dex：Mihon payload 先打开同目录 `.part` 的写入句柄，立即将路径设为只读，再通过已打开句柄复制、`fsync`、完成长度/SHA-256 重验并原子提升为 runtime `extension.apk`；类加载前再次确认只读，失败仍由 activation workspace 统一清理。
- 修复 `VeneraRuntimeDriver` 响应头泛型编译错误。响应适配改为接受 `Map<*, *>` 并逐项净化 String key 与可迭代值，同时兼容 `HttpURLConnection.headerFields` 的 nullable 泛型和 OkHttp 的非空 multimap。
- Venera browse 能力现在把 `load` 与 `loadNext` 都视为正式 loader。token 分页由隔离 runtime 按 source/query/options 保存，支持官方 e-hentai 等 `{comics, next}` 契约，不再在 activation 阶段误报无 browse capability。
- Venera 封面 URI 归一化为绝对 HTTP(S) 地址，普通封面可直接进入同一受控 Network/Cookie/response-limit/图片转换链；章节页面继续使用有生命周期的 `venera-resource://` token，不改变 Reader 或缓存所有权。
- Venera 详情和章节统一输出领域值 `vertical`；Dart adapter 同时接受旧 `topToBottom`、`webtoon`、左右方向长名与规范枚举，未知值仍明确失败。
- Venera source-key 静态检查只读取 `class ... extends ComicSource` 后的第一个类级 `key = "..."`，不再把 Picacg 方法内的 `let key` 等局部变量误判为冲突 metadata。
- 新增产品源码提取式 Kotlin/JavaScript 门禁：nullable/non-null response header 编译、Mihon APK 只读权限、Venera `loadNext` 两页推进、绝对封面资源、方向别名与方法局部 key 回归。

## 0.31.0-dev.56：Mihon payload Context 与 Venera 当前源兼容闭环

- 严格以 dev.55 为基线，并将用户提供的 `git_latest_two_commits.zip` 中 13 个对应文件原样覆盖后继续开发；保留其“读取设备已安装 Mihon 扩展”、Venera gzip/deflate 响应解码、扩展索引/UI 与生成 Android host 升级。
- Mihon activation 现在为 process-private APK 构建 payload 专属 `Context`：包名、`ApplicationInfo`、资源、assets、class loader、theme、LayoutInflater、偏好与文件/cache 目录均绑定到该扩展副本。运行时重新核对 APK 包名和 1.4/1.5/1.6 ABI，避免扩展资源或隔离存储错误表现为泛化 `activationFailed`。
- Mihon 入口兼容 Kotlin `object`、静态 `create/newInstance/getInstance` 工厂、`Context` 构造器和无参构造器；每个入口失败均携带具体类名与根因。Dart `ExternalPluginActivationException` 也保留 native cause，产品 UI 可直接展示可定位诊断。
- Venera browse 兼容当前 `explore` 数组/对象/`Map`、直接 loader，以及 `category.parts[].itemType/categories/categoryParams` 与旧 `target.attributes` 两类分类契约；动态 `optionLoader` 和静态 `optionList` 都转换为真实默认参数，不再仅因对象 key 存在却未识别容器而报告“no browse capability”。
- Venera 网络桥将 `Accept-Encoding` 收敛到宿主实际解码的 gzip/deflate，并继续按 `Content-Encoding` 有界解压。公共域名被系统 DNS 异常解析为空或回环/私网地址时，独立进程可通过受限 DNS-over-HTTPS 获取 A/AAAA 地址，再由 OkHttp 自定义 DNS 保留原域名 TLS/SNI；CNAME、回环、链路本地、私网和组播答案均拒绝。
- 新增从实际 Kotlin/JavaScript 产品源码提取并执行的 Mihon 入口构造、payload Context 编译、Venera 网络策略和 Venera bootstrap 合约门禁，以及 activation cause、当前分类形态和 DNS 过滤回归。Reader、下载、缓存、session/cancel 和专用 runtime process 所有权不变。

## 0.31.0-dev.55：Mihon 单一 ABI 提供者与 release 保留闭环

- 修复 Android release `checkReleaseDuplicateClasses`：`extensions-lib` 现在只作为非传递的 Mihon/Tachiyomi ABI AAR 使用，不再把其旧 POM 中的 Kohesive Injekt 依赖与当前 Keiyoushi common bundle 同时带入 App。
- 移除重复声明的 `androidx.preference:preference-ktx`。当前 pinned `extensions-lib` AAR 已提供该 ABI；宿主继续只显式提供 Keiyoushi 当前使用的 null2264 Injekt、协程、序列化、网络、解析与 QuickJS 运行库。
- 新增 Android 外部运行时依赖闭包检查，禁止重新引入官方旧 Injekt 或第二份 AndroidX Preference，并要求 `extensions-lib` 始终保持 `transitive = false`。
- 新增 consumer R8 规则，保留动态 APK 会引用但静态 App 图不可见的 Source、Preference、Injekt、RxJava、协程、序列化、OkHttp/Okio、Jsoup 与 QuickJS 二进制 API。
- Mihon activation 在创建 class loader 前预检核心宿主 ABI。缺失 Source/模型、Preference 或 Injekt 时明确拒绝 activation，不再延迟为来源空结果或不稳定反射错误。
- 新增 host ABI 缺失报告回归，并保持独立 runtime process、payload 重验、session/cancel、Reader、下载和缓存所有权不变。

## 0.31.0-dev.54：Android 依赖闭环与 Mihon runtime 清理

- 修复 `ExternalPluginController` 恢复 manifest 时调用不存在的 `File.isFile()` 所造成的 Dart 编译阻断。恢复阶段现在只接受插件私有目录中的普通 `.apk`/`.js` 文件，并拒绝目录、外部路径、符号链接和 `.part` 预览文件。
- `tool/configure_platforms.py` 现在同时配置 Android Internet 权限和宿主级 JitPack 仓库。它优先写入 `dependencyResolutionManagement.repositories`，否则写入生成宿主的 `allprojects.repositories`，兼容 Groovy/Kotlin DSL 且保持幂等；插件子工程也统一使用 canonical `https://jitpack.io`。
- 保持 Keiyoushi 当前 1.6 runtime-only 依赖坐标不变，但确保这些依赖由真正解析 `:app:releaseRuntimeClasspath` 的宿主仓库集合获取，不再依赖插件子工程局部 repository 对最终 App 配置生效。
- Mihon 每次 activation 使用包含 `driverId` 的独立 code-cache workspace，避免同插件同版本并行 activation 相互删除 APK、dex 或 native library。activation 失败立即清理；关闭时协作取消请求、关闭 source，并在真实任务排空后删除 workspace。
- 专用 runtime Service 启动时清理上次进程死亡遗留的 Mihon workspace。请求任务改为预注册的 `FutureTask`，关闭/取消发生在任务启动前也能完成 request result 与清理，不再留下未计数的运行时目录。
- 新增 generated-host Groovy/Kotlin repository 回归、manifest 非法 payload 恢复回归及 Mihon workspace 唯一性/陈旧目录清理回归。Reader、下载、缓存和 Home startup 所有权保持不变。

## 0.31.0-dev.53：Mihon/Venera 真实运行时与产品入口

- `plugin_host_bridge` 在既有 `:zic_plugin_runtime` 进程内注册 Mihon 与 Venera 原生 driver；Dart process host 继续拥有 payload 重验、session、取消、并发、响应上限与关闭策略，Kotlin 不复制这些所有权。
- Mihon APK 从 process-private 已验证副本加载，解析批准的 `Source`/`SourceFactory` 入口并兼容现行 1.6 suspend API 与旧 Rx API；browse/detail/chapter/resource 被映射到共用 protocol v1。图片请求优先复用扩展自己的 client、headers 与拦截器，无 client 时才使用平台 HTTP 后备。
- Venera JavaScript 在无 UI、禁用文件/内容访问和 DOM storage 的 process-private WebView 中运行；实现 1.6 `ComicSource`、Network/Cookie/Convert/Storage/HTML/APP/compute 兼容桥、最低宿主版本检查、数组/对象/`Map` 漫画与章节返回兼容、资源 HTTP 失败重试，以及受像素/响应上限约束的 `Image` 裁剪、旋转、拼接和输出桥。
- 漫画源管理新增 Mihon 仓库与 Venera 源仓库入口。下载、不可变 payload 提升、SHA-256/签名/ABI/source-key 检查、显式信任、安装/更新/回滚/移除及重启恢复由 `ExternalPluginController` 统一管理；启动失败直接显示，不伪装成空源。
- Mihon 入口使用当前仓库推荐的 `index.pb` 地址，并兼容 `repo.json`；发现阶段读取同仓库发布的完整 `index.json` companion，并解析当前 `extensionList.extensions` v2 对象及旧版数组，避免旧 `index.min.json` 的升级占位条目，同时不把 protobuf 依赖带入可执行插件边界。
- 外部源仍只作为普通 `BrowsableComicSource` 注入既有 catalog/cache/download/Reader 管线，不获得导航、Reader demand、页面 artifact 或缓存所有权。Home startup 已有核心服务阶段保持不变，插件恢复放在核心服务 ready 之后。

## 0.31.0-dev.52 — generation-aware Binder death and verified packet consumption

- Close the reported compile gap with explicit catalog imports in `runtime_service.dart` and the dedicated-entrypoint regression; declare the bridge test dependency directly instead of relying on transitive package visibility.
- Replace the reusable Android `ServiceConnection` flags with a generation-aware binding state. Each explicit bind gets a new generation and Binder death is observed through `linkToDeath`; stale callbacks from an older service cannot invalidate a newer explicit rebind. Service loss fails each active request once and never replays it.
- Abandon a binding generation when all queued callers time out before the Service connects, allowing a later explicit activation to bind again instead of remaining stuck behind a permanent `binding` flag. Connected-service request timeout does not tear down unrelated sessions.
- Split large-response packet files into a pure file owner with exact root/path/length/SHA-256 verification. The host verifies the digest while performing the one required file-to-codec read, deletes consumed or corrupt packets, and rejects path escape. Inline responses are digest-checked too.
- Add Android JVM regressions for stale service-death callbacks, explicit retry generations, closing callbacks, large packet consumption/deletion, corruption rejection and path confinement. Preserve Home trace, image/Reader ownership, process generations and fail-closed Mihon/Venera drivers.

## 0.31.0-dev.51 — Android dedicated runtime service bootstrap and Binder-safe transport

- Preserve the confirmed `runtime_service.dart` import fix and continue from the dev.50 process-generation endpoint without reopening that compile issue.
- Add a non-exported Android service in the `:zic_plugin_runtime` process. It starts a FlutterEngine with automatic plugin registration disabled and executes the retained `zicExternalPluginRuntimeServiceMain` secondary Dart entrypoint.
- Add a Dart bootstrap that attaches `AndroidExternalPluginRuntimeServiceHandler`, announces the new process generation, and remains fail-closed with no Mihon/Venera driver installed. Kotlin still does not own payload verification, session routing, cancellation or shutdown policy.
- Replace the main-process native fail-closed stub with a lazy bound-service client. Every activation/invoke/cancel/close request is sent once with a correlation identity; service death fails the outstanding request and never replays or transparently reactivates it.
- Add Binder-safe wire framing. Requests are capped below Binder's transaction limit; large binary responses spill to atomic app-private packet files and are decoded/deleted by the host process, avoiding base64 and oversized Binder transactions. Stale `.part`/`.packet` files are cleared on service start/destroy, and unclaimed large responses have a bounded retention timer.
- Add bootstrap/manifest/entrypoint regressions and ADR 0035. Concrete Mihon `Source`/`SourceFactory` loading and Venera JavaScript evaluation remain unavailable drivers inside the dedicated process.

## 0.31.0-dev.50 — compile closure and process-generation runtime service ownership

- Close report-32 compile blockers in product and test dependencies: stream SHA-256 now uses a real `Sink<Digest>`, runtime activation imports the handshake boundary explicitly, and affected tests import `dart:async`/domain `Failure` from their owning libraries.
- Add `ExternalPluginRuntimeServiceEndpoint` as the single dedicated-process dispatcher for Mihon/Venera activation, invoke, cancel, session close and process close. Exact method fields and plugin-format/method agreement are validated before the process host is called.
- Add an unforgeable runtime `processId` generation to every activation. Invoke/cancel/close must carry the same generation, so a service restart rejects stale sessions even when a session ID is reused and never auto-reactivates or replays the failed request.
- Add a Dart-side Android MethodChannel service handler that maps stable service/process errors while delegating all activation parsing, payload staging, session registry and teardown policy to the shared process host instead of duplicating it in Kotlin.
- Add process-service, stale-generation, joinable close, platform-channel and handler conformance tests plus ADR 0034. Concrete Mihon class loading and Venera JavaScript evaluation remain fail-closed driver work.

## 0.31.0-dev.49 — meaningful decode-target regression and process-entry payload ownership

- Fix the reported target-rebuild timeout by using a deterministic 2048×2048 VP8X canvas fixture. The regression now proves that the viewport change produced distinct downsample targets before asserting gapless replacement; a tiny 2×2 source correctly remains a no-op.
- Add strict Mihon/Venera process-entry activation parsing with exact schema fields, plugin-format identity, capabilities and runtime limits.
- Revalidate the inspected payload inside the isolated process, stream it into a process-private atomic copy, and pass only that verified copy to the ecosystem driver. This closes the verify-then-reopen path race.
- Add a process-owned runtime session registry with bounded activation, joinable teardown, source-key validation, cooperative cancel routing and no automatic request replay after process restart. Closing drivers continue to consume a session slot, and process shutdown cannot publish a partially activated session.
- Add payload mutation, staged-file lifetime, Venera source identity and process-restart regressions plus ADR 0033.

## 0.31.0-dev.48 — deterministic controlled-codec tests and drain-safe image teardown

- Close the repeated `local_image_preview_test.dart` shutdown stall at its lifecycle boundary. The plain-file zero-copy assertion is now a pure provider-routing test and never starts a platform `FileImage` decode.
- Extract `FlutterAnimatedCodec`/`FlutterAnimatedCodecFactory` from the controlled animation state machine. Production still uses `ui.instantiateImageCodec`; widget tests inject a deterministic codec so engine-thread WebP completion cannot strand the test platform.
- Publish controlled-animation readiness only after `WidgetsBinding.endOfFrame`, retain the previous frame until its replacement is visible, and dispose the retained frame when a generation is invalidated during presentation.
- Put every async image regression behind unconditional widget teardown. Failed assertions now cancel timers, dispose codecs/images and yield the event loop before the next test; cold Reader artifact polling uses the same bounded real-event deadline.
- Preserve Home startup trace and the dev.47 Mihon/Venera worker/platform-channel boundaries unchanged. Record ADR 0032; concrete isolated APK and JavaScript drivers remain downstream work.

## 0.31.0-dev.47 — isolated runtime worker, cooperative cancellation and platform backend channels

- Add one server-side `ExternalPluginRuntimeWorker` shared by Mihon and Venera isolated backends. It reparses protocol-v1 requests inside the isolation boundary, rejects unknown sources and duplicate active request IDs, sanitizes backend failures, tracks real work and owns deterministic teardown.
- Add cooperative request cancellation across raw runtime channels. A caller timeout sends best-effort cancellation when supported, while the host concurrency permit remains occupied until the underlying backend Future actually exits.
- Serialize immutable Mihon/Venera activation envelopes, approved capabilities and exact runtime limits across the platform boundary. Add Android host-side method-channel backends for activation, invoke, cancellation and close; the native bridge remains fail-closed until a dedicated APK/JavaScript service is installed.
- Add conformance regressions shared by both ecosystems for browse/comic/chapter/resource operations, unknown and duplicate identities, timeout cancellation, retained concurrency, joinable close and platform-channel serialization.
- Preserve the existing Home startup trace and the dev.46 local-image/cold-artifact lifecycle fixes unchanged. Record ADR 0031; concrete Mihon class loading and Venera JavaScript evaluation remain separate isolated-driver work.

## 0.31.0-dev.46 — single image-stream ownership, active-run artifact priming and raw runtime channel

- Close report-30's local-image test stall by removing the second manually resolved `FileImage` stream. Static image readiness now comes only from the renderer-owned `Image.frameBuilder`; the zero-copy file-routing regression verifies `FileImage` without waiting for a host codec and explicitly unmounts the provider.
- Yield the real event queue for host codec work in animation and cold-artifact widget regressions, then explicitly unmount animated players so codecs/timers do not leak into later tests or suite shutdown. Product ready still means a frame was actually presented.
- Prime promoted page artifacts at authoritative `DownloadSession.beginRun`, before ephemeral workspace restore, while keeping pages join-only. Add coverage for observers attached after a run already became active.
- Add a raw, versioned external-plugin runtime message channel and handshake around protocol v1. Every call serializes across the boundary, validates response/request identity, rejects duplicate source identities and exposes joinable close without leaking Reader/download/artifact objects.
- Preserve the existing Home startup trace unchanged, add regressions and ADR 0030. Concrete Mihon class loading and Venera JavaScript evaluation remain isolated backend work.

## 0.31.0-dev.45 — versioned external runtime protocol and shared source adapter

- Close report-29's constant-evaluation blocker by keeping `ExternalPluginRuntimeLimits` const-capable while validating `Duration` positivity at executor/session activation instead of invoking relational operators in a const initializer.
- Add one versioned, ecosystem-neutral request/response protocol for browse, comic, chapter and binary resource operations. The wire schema accepts only bounded method-channel-safe values and never exposes Reader, demand, `DownloadSession` or artifact APIs.
- Adapt isolated Mihon and Venera runtime connections through one `ExternalPluginRuntimeSession` into ordinary namespaced `BrowsableComicSource` instances, with strict source/comic/chapter/page identity validation.
- Enforce invocation timeout, response bytes and concurrency again at the host boundary. A timeout no longer releases its permit until the underlying isolated call actually exits; queued calls cannot steal or overbook transferred permits.
- Make concurrent session close calls join one shutdown, signal the isolated connection before draining real work, reject queued work deterministically and close failed handshakes.
- Preserve the existing Home startup trace unchanged, add protocol/runtime lifecycle regressions, and record ADR 0029. Concrete Mihon class loading and Venera JavaScript evaluation remain isolated backend work.

## 0.31.0-dev.44 — visible-frame readiness, authoritative artifact priming and plugin execution contracts

- Close the report-28 compile blocker with the explicit `ResourceCacheFileByteStore` composition capability. File lookup and durable invalidation now share one statically valid owner instead of relying on promotion to the intersection of unrelated nullable interfaces.
- Make local WebP readiness mean an actually presented first frame rather than container validation. Cold-codec and target-rebuild regressions use the packaged animation fixture and retain strict visible-frame/no-black-gap assertions.
- Prime promoted-artifact reads when the authoritative replacement `DownloadSession` enters queued/receiving state. Page consumers still only join that single read; they do not create cache or network demand. Promotion waiting now checks session state before and after listener attachment.
- Extend Android Mihon pre-load inspection with normalized extension entry classes, while continuing to forbid class loading during inspection. The trust gate rejects executable activation metadata that lacks an entry class.
- Add separate immutable-payload execution request contracts for an isolated Mihon backend and a bounded Venera JavaScript backend, including invocation, response, concurrency and runtime-heap limits. Concrete engines remain downstream adapters and cannot bypass inspection, trust or session identity validation.
- Preserve the existing Home startup trace without adding new cold-start work, add queued-read and runtime-request regressions, and record ADR 0028.

## 0.31.0-dev.43 — compact cover manifest, attributable Home startup and Android Mihon metadata

- Close the external dev.42 compile blockers in product code: encoded memory sources no longer use a runtime value in a const initializer; durable file-store capabilities are explicitly narrowed; chapter bulk projection parenthesizes nullable async fallback correctly; and local animation branches require non-null encoded bytes before constructing byte-owned players.
- Replace per-cover warm metadata reads with one storage-owned `response-manifest-v1.json`. Per-entry journals remain for atomic crash recovery/migration, target file length is still verified, LRU touches are batched, and warm hits continue to return immutable file references without whole-file Dart copies.
- Add a monotonic Home startup trace covering Flutter bootstrap presentation, service-open phases, cover request, encoded source origin/length and first decoded frame. Encoded sources now distinguish memory, ordinary local files and durable cache files explicitly.
- Add the Android `plugin_host_bridge`: Mihon APK archive inspection runs off the platform thread and reads package, current signer SHA-256, version code and supported extension ABI metadata through `PackageManager` without class loading.
- Make bounded Venera inspection derive UTF-8 metadata and SHA-256 from one immutable byte snapshot, preserving repository/script key agreement and non-execution.
- Add manifest reopen/migration, encoded-origin, Home telemetry, Venera invalid-payload and Android bridge regressions, plus ADR 0027.

## 0.31.0-dev.42 — file-backed Home covers, lazy startup and concrete plugin inspection

- Correct the cold-start diagnosis: mount Flutter immediately with a startup surface, remove eager restoration of every indexed offline page, avoid a duplicate application-support path lookup, bulk-load read-state projection in one query, and project Home download badges from one SQLite index scan without materializing sessions or statting page files. Exact page commands alone restore artifacts.
- Add a file-backed encoded-image contract. Durable cover hits validate the exact key, expiry and length, then pass the immutable cache file to `FileImage` without whole-file `readAsBytes`, startup hash recalculation or per-hit metadata flush. Access recency is batched until store close, and in-process file locations are reused.
- Let ordinary local static images use the same file-provider path when no Reader/pipeline loader owns the request. Android content URIs, animations and Reader pages retain controlled byte/session fallbacks. The implementation avoids Dart-heap copies but does not claim absolute storage-to-texture zero copy inside platform decoders.
- Publish Flutter animated `ready` only after the first frame has actually been presented, retain the gapless target-rebuild invariant with a real packaged WebP fixture, and keep the cold promoted-artifact regression state-driven.
- Add concrete Mihon APK and Venera JavaScript payload inspectors over one immutable local payload: streaming SHA-256, exact-length checks, metadata-only APK parsing boundary, bounded non-executing Venera key discovery, and repository/script key agreement. Executors remain separately sandboxed adapters.
- Add file-backed cache, batched-touch, direct local-file provider, lazy artifact restore and plugin-inspection regressions, plus ADRs 0025 and 0026.

## 0.31.0-dev.41 — direct promoted reads and gapless cold decode

- Fix the reported `static_demo.dart` compile failure by importing the downloads-owned Reader page identity adapter rather than relying on a re-export side effect.
- Let a reopened Reader consume one exact immutable read of an already-promoted page artifact while the replacement `DownloadSession` continues its normal seal/promote path in the background. The page and cache transport share that read through a downloads-owned pool, removing cache-to-ephemeral-copy and re-read from first-frame latency.
- Stream background cache handoff in 64 KiB chunks and use the exact DownloadId/length as the resume validator, avoiding a second whole-page hash and giant single-chunk copy on the UI isolate. Cache read failures now fall back through the normal session/origin path with trace evidence.
- Keep the currently presented Flutter animated frame during target-only codec rebuilds and replace it only after the new frame is presented, eliminating the black gap caused by eager frame disposal. Encoded-byte changes still invalidate the frame.
- Extend transition replay with durable artifact read duration and consumer attribution, preferring the Reader-direct event when both direct consumption and session-copy events exist.
- Preserve the strict midpoint invariant before gesture release while allowing the old page to be evicted after settling; the regression still forbids a loaded page remount. Add cold-open, coalesced-read, chunking, fail-open cache, Flutter codec phase and gapless-target regressions, plus ADR 0024.

## 0.31.0-dev.40 — managed artifact capability and deterministic transition replay

- Close the reported App compilation failure without widening every chapter-download implementation: add the explicit
  `ManagedChapterDownloadService` composition capability, implemented by the memory and persistent services, and use it
  at the durable App root where artifact maintenance is required. The narrower `ChapterDownloadService` remains valid
  for UI/test adapters that do not own promoted artifacts.
- Replace the Reader midpoint regression's fixed-pixel assumption with state-driven gesture progression. The test first
  proves the target host entered the render tree while the original page is still current, then crosses the actual
  midpoint and verifies neither loaded host was disposed or recreated. Product keys and ownership are not weakened.
- Add deterministic `ReaderTransitionTraceAnalyzer` replay over the existing transition/artifact/decode/upload/present/
  first-frame/host-lifecycle trace chain. It reports cache versus origin selection, host-remount evidence, phase durations,
  missing evidence and the dominant measured phase without changing demand, retention, cache or eviction policy. The
  replay distinguishes transition revision from the revision that produced the presented frame and emits a JSON-ready
  report, so a preloaded neighbor is measured as zero transition wait instead of being attributed to later swipe work.
- Move Reader page DownloadId/trace identity construction into `downloads`, add rapid-swipe, incomplete-trace,
  host-remount and managed-capability regressions, plus ADR 0023 and updated handoff
  rules for evidence-driven retention work.

## 0.31.0-dev.39 — compile closure, transition attribution and permissioned plugin hosts

- Close the reported dev.38 Dart compilation regressions: durable `Uint8List` restoration is explicitly narrowed back
  to the caller's generic type, byte-store maintenance uses its promoted capability interface, and the stable Reader
  page host constructor accepts the `key` supplied by `PageView`.
- Move the production durable response-cache composition into one reusable storage-bridge factory and add an app-level
  two-start regression that restores both source-card and comic-detail covers through the real file-backed cache without
  invoking the raw source after restart.
- Add revision-correlated Reader/pipeline telemetry for page transition coverage, page-host mount/dispose, first-frame
  delay, artifact-cache versus origin bytes, decode demand/start and upload demand/start. Demand revisions are captured
  when work is created so a later plan cannot relabel queued work.
- Add the dependency-light `plugin_host` package. It gates Mihon-compatible APKs by repository, payload, package,
  signer, version and extension ABI metadata, and gates Venera-compatible JavaScript by repository, payload, stable
  source key and explicitly allowed capabilities before any executor receives code.
- Add plugin failure quarantine and a runtime registry that owns activated sessions, deactivation and shutdown while
  rejecting source identities already registered by another plugin. APK/Kotlin and JavaScript execution remain separate
  executor interfaces and are not claimed by this iteration.
- Add regressions for real cache restart, artifact-origin attribution, midpoint host preservation, demand/start/frame
  revision ordering, plugin gate rejection before execution, quarantine, runtime source validation and cross-plugin
  identity collision cleanup.

## 0.31.0-dev.38 — durable cover cache, stable Reader hosts and plugin catalog seam

- Persist complete `imageBytes` responses through an injected `ResourceCacheByteStore`. The file implementation stores
  the full cache key, expiry, content length and hash under the durable app root, applies bounded LRU trimming and
  restores covers before invoking a source loader after process restart.
- Extend the standard image-response TTL to seven days while preserving exact namespace invalidation, revision-aware
  identities and explicit refresh. Graceful cache shutdown now rejects new work but drains already-owned requests and
  persistence writes instead of invalidating a cover that completes during exit.
- Keep Reader page and zoom hosts keyed by stable asset identity. Crossing the PageView midpoint updates the current
  role and resets page-local zoom without disposing/recreating the loaded media child, eliminating the observed
  neighbor-page return to black/loading caused by role-key remounts.
- Add format-neutral Mihon extension and Venera JavaScript repository catalog models, strict index parsers, namespaced
  external source identities and an explicit plugin-session lifecycle boundary. Venera parsing accepts both the
  documented `filename` spelling and the current repository's `fileName` plus declared `key`; APK/Kotlin and JavaScript
  execution remain separate future sandbox hosts rather than entering catalog, Reader or download ownership.
- Include durable response bytes in unified cache inspect/trim/clear reporting and Download Manager presentation without
  bypassing page-artifact busy/ownership rules.
- Add regressions for process-reopened cover reuse, close-time persistence draining, source-revision separation,
  durable store expiry/invalidation/LRU maintenance, midpoint page-host preservation and external plugin identity parsing.

## 0.31.0-dev.37 — promoted Reader artifact cache handoff

- Persist exact Reader page bytes only after the authoritative `DownloadSession` reaches `promoted`. A package-owned
  `PromotedArtifactCacheHandoff` observes session state and drains commits before the ephemeral Reader workspace is
  removed; Presentation does not choose pages, start downloads or own a private byte cache.
- Add `ArtifactCacheStore` and `ArtifactCacheTransport` in `downloads`. A new Reader session first checks the durable
  page-artifact tier and falls back to the transport selected by `LiveCoordinator`; duplicate URI identities bypass the
  cache and range reuse requires a content-derived validator.
- Make persistent and memory chapter services expose page-granular artifact read/commit operations. Durable handoff
  writes still pass through `DownloadJob -> DownloadSession -> seal -> promote` and the existing index/`CacheOps`
  maintenance path instead of copying files or mutating the index from App code.
- Keep `resource_cache` dependency-light. It continues to own reusable source-response policy and artifact maintenance
  coordination, while `DownloadId`-specific storage remains in `downloads`.
- Remove the requested negative-TTL assertion from `ResourceCachePolicy`. Repair failed in-flight request coalescing so
  one source failure is delivered only through the caller-owned futures rather than an extra unobserved derived future.
- Restore the Download Manager empty state when cache statistics are present but no chapter/whole-comic tasks exist.
- Add regressions for failed request coalescing, exact cache hits, range validators, ambiguous URI fallback, promoted
  handoff, in-memory artifact clearing and persistent reuse after service reopen.

## 0.31.0-dev.36 — unified resource cache and restored pipeline ownership

- Correct the `0.30.0-dev.35` cache boundary. Remove the App-owned `CoverMemoryCache` and competing `ReaderPageBytesCache`; Reader presentation no longer warms current/adjacent page bytes or enables implicit page retention outside pipeline policy.
- Add the workspace-level `resource_cache` package. Cover/image responses, comic details, chapter metadata and search results share one global/per-kind budget, TTL, in-flight coalescing, LRU eviction, exact source-composite namespaces and stale-response suppression after refresh/clear.
- Add `CachedBrowsableComicSource` in catalog. Explicit source refresh invalidates the relevant search or comic namespace; chapter page `loadResource` remains a raw pass-through so encoded pages continue through demand/session/artifact ownership.
- Move chapter artifact downloads and durable whole-comic scheduling out of `apps/app/lib` into `downloads`. Move runtime network/power and JSON persistence adapters into `downloads_bridge`; the queue now explicitly closes owned environment adapters after draining work. Download Manager stays a presentation/command surface over package interfaces.
- Model partial offline chapters as independent page artifacts plus separately cached chapter metadata. `ResourceCacheCoordinator` owns shared maintenance policy and reports both planes without turning a chapter into an all-or-nothing cache entry or leaving capacity thresholds in Presentation.
- Make the memory fallback mirror production artifact semantics: each completed page is retained immediately, cancellation/failure preserves the downloaded subset, retry skips retained pages, and trim/clear evicts page records rather than whole chapters. Folder imports persist their first page as explicit cover metadata; a missing remote cover no longer silently routes a chapter page through the response cache.
- Keep cache identity construction in package adapters. App composition injects an existing coordinator unchanged, and does not construct `ResourceCacheKey` values or replace an injected maintenance policy.
- Restore Reader page-role remount semantics required to reset stale zoom and remove the invalid stable-page-identity regression. Fix the reported cache-maintenance type promotion and invalid imported-page cover field.
- Add regressions for cache namespaces, per-kind statistics, refresh supersession, clear-during-in-flight behavior, catalog cache/raw-page boundaries and platform queue persistence.

## 0.30.0-dev.35 — home decomposition and bounded media caches

- Split the 3300+ line Home shell into durable `HomeLibrarySession`, Home/Bookshelf view composition, reusable cover/shelf Widgets and a smaller navigation/use-case coordinator. Enforce a first-stage line budget on `demo_home.dart`.
- Add bounded, concurrent-load-coalescing LRU cover bytes instead of the previous unbounded process-lifetime map. Cover Widget decode targets now follow rendered size/DPR and retain the previous frame during replacement.
- Add a bounded Reader encoded-page cache with current/next/previous warmup, shared in-flight loads and obsolete-warmup cancellation. Stable page keys and implicit adjacent retention avoid remounting media solely on page-role changes.
- Expose persistent chapter-cache usage, trim and clear through Download Manager while keeping artifact/index ownership in storage and `ChapterDownloadService`. Completed/download/Reader state is not owned by the cache UI.
- Add deterministic cache, eviction, warmup, session projection, cache-maintenance and page-identity regressions. This iteration does not move native decode/frame/texture ownership into the App.

## 0.29.0-dev.34 — source migration candidate comparison

- Add an authoritative pre-write comparison for cross-source comic migration. The current and target works are shown side by side with cover, authors, source/native identity, reading direction and chapter counts.
- Add catalog-owned migration evidence: normalized title/author overlap, exact and sequence-only chapter counts, unmatched source/target chapters, chapter-pair samples and explicit risk flags.
- Require an explicit identity/risk acknowledgement before the existing conservative copy flow can continue. The comparison performs no durable writes and does not weaken target chapter identity verification.
- Cache each comparison cover load for the dialog lifetime so checking the acknowledgement box cannot repeat a remote cover request.
- Add catalog and Widget regressions for risk evidence, chapter samples, source/target identities and the disabled-before-acknowledgement confirmation action.

## 0.28.1-dev.33 — download manager OOM and queue shutdown repair

- Restore the missing `index++` in Download Manager's chapter-task list expansion. The old loop never advanced once at least one chapter snapshot existed, causing unbounded Widget construction and eventual process/WSL OOM.
- Close `WholeComicDownloadQueue` by first cancelling and draining active chapter work, then publishing the resumable final queue state, cancelling environment signals and closing the queue store/stream.
- Replace the affected chapter-download, library and source-browser tests with bounded frame waits and explicit route/widget teardown supplied in `apps.zip`; no product interaction is changed to satisfy those tests.
- Add a Dart structure gate that rejects conditional C-style `for` loops with an empty update clause, catching this OOM class before Flutter execution.

## 0.28.0-dev.32 test-harness correction — no product behavior change

- Advance simulated frame time while waiting for popup routes, route transitions, enabled buttons and refresh results instead of looping with zero-duration pumps.
- Wait for the Reader speed option to become hit-testable without changing the Reader speed UI again.
- Make paused whole-comic queue persistence assertions tolerant of an already-returning page while still proving that a restored paused job starts no new chapter.
- Release blocked test page loaders during teardown so a failed assertion cannot leave download services and Flutter test channels waiting indefinitely.
- Product code and package versions remain unchanged from `0.28.0-dev.32`.

## 0.28.0-dev.32 — durable whole-comic queue and runtime policy signals

- Replace the route-owned sequential whole-comic loop with `WholeComicDownloadQueue`, a durable JSON-backed
  scheduler keyed by exact `sourceId + comicId`. Restored jobs keep their chapter catalog and completed set;
  a process interruption converts an in-flight job back to queued work without taking ownership away from
  the existing per-chapter download service.
- Add global chapter concurrency limits, pause/resume, cancel/retry and queue-record removal. Duplicate enqueue
  requests coalesce while a job is active, and terminal chapter artifacts are re-inspected before scheduling.
- Add network and power gates. The queue can require an unmetered connection or charging, suspends active
  chapters when a condition becomes false, and resumes through the same `ChapterDownloadService` when the
  condition becomes valid again.
- Add the `runtime_bridge` Flutter/Android plugin. It reports validated network availability, Android metered
  state and battery charging state through versioned method/event channels; unsupported hosts retain the
  explicit injectable fallback instead of becoming another download owner.
- Extend Download Manager with a durable whole-comic queue section, queue policy configuration and per-job
  pause/resume/cancel/retry/remove actions while retaining the existing authoritative chapter task section.
- Restore the missing exhaustive bookshelf sort label that blocked App compilation, and replace the clipped
  Reader speed popup with a centered bounded dialog whose five options remain hit-testable on small windows.
- Add deterministic queue regressions for concurrency, policy waiting, policy loss during an active chapter,
  paused-job restoration, JSON restoration and Download Manager queue controls.

## 0.27.0-dev.31 — cover management and whole-comic downloads

- Restore management actions to each cover: delete at the upper-right and category migration through a
  popup at the lower-right. Remove the duplicate single-selection action surface; long-press starts
  source-composite multi-selection and the separate batch bar only owns batch move/copy/clear/delete.
- Preserve custom gallery ordering with a dedicated drag handle so reordering does not compete with the
  long-press multi-select gesture. Keep sort and category migration as bounded popup menus rather than
  bottom sheets.
- Make details subscribe to authoritative `ChapterDownloadSnapshot` state. A chapter keeps its spinner
  after route recreation, uses its own title and page denominator, and leaves the cover waterline
  immediately on completion.
- Add whole-comic download to the shared local/remote details header. It resolves the catalog once,
  downloads incomplete chapters sequentially through the existing chapter service, stops after
  cancellation, and preserves per-chapter task ownership in Download Manager.
- Project an active chapter or whole-comic task onto the shared cover; completed tasks use only a compact
  offline badge. Download Manager promotes the chapter name and omits the progress bar for completed
  tasks.
- Remove source/progress rows below covers, overlay the comic title at the lower-left, and keep reading
  progress in details. Coalesce rapid Home/History/Bookshelf/Source cover taps by exact source-composite
  route identity.
- Repair small-screen Reader speed-menu reachability, restore-unread ListTile material ownership, remote
  retry/pull-refresh controls and stable management interactions without changing product semantics only
  for tests.

## 0.26.0-dev.30 — migration diagnostics and interaction reliability

- Upgrade SQLite to schema version 6 by adding durable acknowledgement timestamps to
  `library_migration_issue`; pending and acknowledged records remain queryable without deleting or
  rewriting ambiguous legacy state.
- Add a Bookshelf Migration Diagnostics surface with refresh, selectable details, JSON clipboard
  export, pending/all filtering and individual or bulk acknowledgement.
- Keep the separate local/remote details owners while splitting chapter open and download locks;
  coalesce concurrent manifest persistence for the same source-composite chapter.
- Replace the restore-unread `Dismissible` lifecycle with a non-destructive right-swipe action so the
  row never leaves the chapter list while read state is persisted.
- Keep Reader controls at their final overlay positions while fading, making pause/speed/rotation and
  other controls hit-testable as soon as they are shown.
- Replace fragile bookshelf sort and category-move popup menus with explicit bottom-sheet choices and
  stable interaction identities; open Download Manager synchronously before refreshing snapshots.
- Repair reported cover/shelf fixtures, download/open ownership regressions, remote pull-refresh/retry
  interaction paths and schema-6 acknowledgement migrations without weakening product assertions.

## 0.25.0-dev.29 — authoritative download management and UI regression repair

- Add `ChapterDownloadSnapshot` and a common task lifecycle (`idle`, `downloading`, `complete`,
  `failed`, `cancelled`) to the chapter download boundary, including exact source-composite identity,
  comic/chapter labels, completed/total pages, received/total bytes and copyable failure details.
- Derive persistent progress from the existing `DownloadRegistry`, `DownloadSession` and promoted
  artifacts. Keep terminal phases authoritative while late progress callbacks drain, and preserve
  partial artifacts for retry/resume.
- Add a Download Manager reachable from Home and Bookshelf with per-chapter cancel, retry and
  confirmed offline-file deletion. Deleting bytes deliberately retains saved comics, chapter
  metadata, reading progress and read state.
- Project aggregate chapter progress onto the shared Home/History/Bookshelf cover component. Show a
  dimmed bottom-up waterline only while incomplete; restore the cover and show a compact offline badge
  when all known pages are durable.
- Fix missing-cover records so a failed/absent cover becomes a stable placeholder rather than a
  synchronous Widget-build exception.
- Mark a chapter read before opening Reader, remove the duplicate details title, make source
  management visibly reachable, and give sort/category/retry controls stable interaction identities.
- Make Reader pause/continue rebuild from its playback notifier and keep the existing media pipeline.
- Add deterministic cancel/retry/delete and Download Manager regressions, plus stronger Dart structure
  checks for nested duplicate named arguments and product contracts.

## 0.24.0-dev.28 — source-composite durable library schema

- Migrate SQLite to schema version 5 so imported chapters, reading progress, comic preferences and
  chapter read state use source-composite primary keys rather than source-agnostic native IDs.
- Carry `sourceId` through `ReadingProgress`, `ComicPreference` and `ChapterReadState`, with explicit
  fallback decoding for legacy JSON and source-aware Store point queries/removals.
- Upgrade schemas 1–4 transactionally. Resolve legacy chapter-owned data from its imported chapter;
  resolve ambiguous remote preferences deterministically and persist an auditable
  `library_migration_issue` record instead of overwriting or silently dropping state.
- Remove cross-source native-ID conflict guards now made obsolete by composite storage. Two sources
  can retain the same comic and chapter IDs with independent progress, preferences and read state.
- Preflight every exact cross-source chapter match before the first durable write; merge target comic
  preferences and preserve existing target progress/read state instead of overwriting it with source state.
- Run `PRAGMA foreign_key_check` before committing a legacy schema upgrade so an invalid composite
  ownership graph rolls back rather than becoming the active library.
- Make Home/history/source cards and details chapter/read/download Widget keys source-composite so
  Flutter state cannot be reused across equal native IDs from different sources.
- Fix the reported `void` callback conditional returns and type-safe legacy `SavedComicRecord` list
  decoding without weakening product tests.
- Add schema 4→5 ambiguity-reporting, duplicate-native-ID isolation and legacy JSON fallback
  regressions; make legacy schema preparation recover development databases whose version marker was
  written before every table existed.

## 0.23.0-dev.27 — two detail owners, whole-comic shelf, durable chapter downloads

- Replace the single stateful details owner with `RemoteComicDetailsScreen` and
  `LocalComicDetailsScreen`, while reusing the same header, preference/category controls, chapter
  rows, error panel and pull-to-refresh scaffold.
- Centralize exact `sourceId + comicId` routing: an unsaved source work stays remote; durable comic
  metadata or chapters route the same source work to local details.
- Add `SavedComicRecord` and SQLite schema version 4 so a whole comic can be liked, collected or
  added to the shelf without importing an arbitrary chapter. Persist a lightweight source chapter
  catalog for the local details page.
- Make the primary chapter trailing action a durable offline download. Persist promoted page
  artifacts outside the Reader session workspace and reuse complete offline bytes after restart;
  the in-memory fallback also owns actual page bytes before reporting completion.
- Add conservative cross-source copy migration for whole-comic preferences plus exact
  title-and-sequence chapter matches. Search the selected target source by the current title, let the
  user choose a candidate (with manual native-ID fallback), fetch target manifests anew, clamp
  migrated progress, copy read state, retain the original source and never copy source URLs or
  offline bytes.
- Use source-aware comic identities for aggregation, management selection, category insertion,
  custom drag targets and Widget keys. Guard legacy native-ID collisions instead of overwriting the
  current preference/chapter/read tables.
- Fix the missing `ImportedChapterRecord` import reported by the compiler and replace fragile
  indefinite animation settling/off-screen taps with state-bound product regressions.
- Replace the framework multi-tap recognizer dependency with a Reader-owned tap window so double-tap
  zoom keeps the real gesture path without leaving a pending test timer.

## 0.22.0-dev.26 — unified source-aware comic details and pull refresh

- Replace the separate remote details presentation with one `UnifiedComicDetailsScreen` used by
  Comic Sources, Home updates, reading history and Bookshelf routes.
- Merge the complete upstream source chapter catalog with persisted library entries by
  `sourceId + chapterId`; retain saved chapters that temporarily disappear upstream and never
  import newly discovered chapters until the user opens or explicitly adds them.
- Add pull-to-refresh and an app-bar refresh command. Source manifests and local-folder snapshots
  refresh through their owning boundaries, then reconcile into the same aggregate projection.
- Persist remote comic authors and description in backward-compatible chapter JSON so a Home/history
  details route retains the same metadata and cover as the source route before its network refresh.
- Keep read/dimming, restore-unread swipe, shelf/like/favorite/category actions, source filtering,
  chapter ordering, selectable diagnostics and Reader opening behavior identical across entry routes.
- Fix the missing domain model import that caused `Comic`/`Chapter` compilation failures in the App.
- Drain the Flutter double-tap recognizer timer after the real two-tap Reader zoom regression instead
  of weakening or removing the product gesture assertion.
- Add regressions for shared source/Home details, non-persisting pull refresh, metadata persistence,
  source-aware chapter state and legacy JSON compatibility.

## 0.21.1-dev.25 — Android source networking and copyable diagnostics

- Repair generated Android hosts by idempotently adding `android.permission.INTERNET` to the main
  manifest after `flutter create`, before Android builds, and before the repository Android runner.
- Add `tool/run_android.sh` so local runs use the same host preparation path as APK builds.
- Add a bounded HTTP connection timeout, source user agent, complete socket OS-error details and one
  short retry for transient MangaDex network failures.
- Replace truncated source errors with a clean diagnostic card containing a focused summary,
  actionable guidance, scrollable `SelectableText`, long-press selection and one-tap full copying.
- Add copy actions to secondary source failures without weakening retry or source-state behavior.
- Replace the unavailable `WidgetTester.doubleTap` call with two real timed taps while preserving the
  Reader zoom assertion and product gesture path.
- Add regressions for DNS failure presentation/copying, MangaDex transient retry and generated-host
  permission idempotence.

## 0.21.0-dev.24 — remote comic source browser

- Add a third `漫画源` application destination with a top source-management action and a bottom
  enabled-source switcher.
- Add catalog-owned remote browsing contracts, searchable/paged source UI, source details and
  chapter actions.
- Add a first-party MangaDex source using its API and MangaDex@Home page manifests, restricted by
  default to English safe/suggestive results.
- Route saved/opened remote chapters through `ImportedChapterRecord`, the durable library and the
  existing Reader DownloadSession/artifact pipeline.
- Persist source enablement and order in SQLite schema version 3, including schema 2 migration.
- Persist source-provided page IDs independently of rotating remote delivery URLs so refresh keeps
  the same reading page and sub-page offset.
- Retry transient comic-detail failures in place and bound remote metadata/cover response bodies
  before buffering them in memory.
- Add fixture transport tests, source-page widget tests, source preference persistence/migration
  tests and remote URL-rotation reconciliation coverage.
- Keep Mihon-compatible plugin runtime support as a later isolated adapter rather than embedding
  Android extension code into the Flutter UI process.

## 0.20.0-dev.23 — library management and immersive Reader controls

- Remove the Home local-directory maintenance panel while retaining folder import and the
  catalog/source refresh contracts outside the primary product surface.
- Reuse the same fixed-size `ComicCoverCard` for Home update/history rails and the Bookshelf
  gallery, including centered exact-width grid layout instead of stretched covers.
- Keep custom sorting in the selected gallery/list view; add a view toggle, long-press cover
  dragging in gallery management mode, and reorderable rows in list management mode.
- Add category-scoped comic insertion plus management selection with move, category membership,
  copy-info and confirmation-gated deletion; visually isolate the destructive action.
- Remove duplicate shelf labels and selected-chip checkmarks, and collapse diagnostics behind an
  explicitly secondary Home section.
- Start Reader in immersive mode with hidden top/bottom controls; tapping reveals page slider,
  animation pause/speed, rotation, favorite and chapter-cache actions.
- Add pinch/pan and double-tap zoom, disable page swiping while zoomed, and reset stale zoom when
  navigating away from a page.
- Route GIF and WebP pause/speed through the existing player ownership path, retaining download
  identity, telemetry, native fallback and viewport-aware decode raster selection.
- Add Flutter regressions for shared cover geometry, custom gallery drag ordering, category add/
  move actions, Reader controls, rotation and zoom reset.

## 0.19.0-dev.22 — comic-level library aggregation

- Fix the catalog and SQLite library test files so all registrations remain inside
  `main()`, restoring Dart test loading without weakening product assertions.
- Move the chapter read/unread gesture key onto the owning `Dismissible` and use a
  deliberate 18% non-destructive threshold, so right-swipe reliably restores unread.
- Add persisted `comicTitle` and chapter `sequence` metadata with backward-compatible
  JSON decoding for existing imported-library records.
- Preserve aggregate identity, title and sequence when a local directory chapter is
  rescanned, while replacing only the refreshed source revision and page snapshot.
- Add `LibraryComic` as a catalog projection that groups local or remote chapters by
  comic identity, selects cover/latest/resume chapters, and exposes aggregate page data.
- Drive Home, Bookshelf, custom ordering, categories, deletion, cover cards and details
  from comic aggregates while retaining per-chapter refresh, progress and read state.
- Add catalog, SQLite and Flutter regressions for multi-chapter grouping, preference
  lifetime, chapter selection and the repaired read-state transition.

## Unreleased — Android home, bookshelf, and comic details

- Add Android-first Home and Bookshelf destinations backed by the durable local library.
- Add update and reading-history cover rails, animated cover bytes, and download waterline progress presentation.
- Add local/remote and custom-category filters, management deletion, standard sort modes, and persisted custom drag ordering.
- Add persistent liked, in-shelf, collected, category, and chapter-read state with SQLite schema v2 migration.
- Add comic details with chapter order reversal, dimmed read state, and swipe-right restore-to-unread behavior.
- Keep local folders without metadata on the direct Reader path while retaining a details route for metadata-capable sources.
- Replace stale App-level PNG fixtures with complete PNG data and stabilize keyed smoke-test discovery.

## Unreleased — persisted local-directory refresh

- Add bridge protocol 3 and `scanImageDirectory` for rescanning a persisted Android SAF
  tree without reopening the picker; desktop refresh reuses the stored directory path.
- Derive imported Reader page IDs from stable source identities instead of page indexes.
- Reconcile memory and SQLite reading progress to the same source when refresh inserts or
  removes earlier pages, and clamp only when the current source disappears.
- Add per-chapter refresh controls and added/removed page diagnostics to the local library.
- Replace the truncated PNG directory fixture with a complete one while keeping strict
  rejection tests for bare signature and incomplete IHDR data.

## Unreleased — durable imported directory library

- Reject bare or truncated PNG container labels during Dart and Android directory sniffing.
- Persist imported folder chapters and per-page detected media formats in a local catalog.
- Add SQLite storage plus Flutter application-support path composition for the catalog.
- Restore the last Reader page and paged/continuous mode when reopening an imported chapter.
- Route reopened content URI and filesystem pages through LoaderTransport, DownloadSession,
  promoted artifacts, and the same Reader runtime as freshly imported folders.
- Clamp saved progress when a refreshed chapter loses pages, ignore stale progress writes,
  and cascade-delete progress when a chapter is removed.

## Unreleased — local-media boundary and Android folder import repair

- Move local image models, recursive filesystem scanning and format sniffing from the App
  package to `packages/local_media`.
- Keep Android SAF documents as MIME/name candidates when a header probe is unavailable,
  and read them through ordinary, asset or typed-asset content resolver streams.
- Add local-media bridge protocol version 2 to detect stale native plugin caches.
- Add `tool/clean.sh` for project-wide Flutter/Dart, Gradle, Rust, CMake and JNI cache cleanup.

# Changelog

## Unreleased fixed-overlay candidate from 0.18.3-dev.21

- Generalized directory import from extension-filtered WebP files to header-detected
  local images, including extensionless and incorrectly named image files.
- Added PNG/JPEG/GIF/WebP/BMP/TIFF/ICO/AVIF/HEIF signature recognition, stronger
  container-prefix checks, recursive natural sorting, and scan/unreadable diagnostics.
- Pinned the Android file-selector implementation that returns directory paths and
  rejects unexpected `content://` results as a path-capability error instead of an
  empty-image-folder result.
- Split Reader/folder smoke coverage from decoder completion: smoke tests assert
  component identity and explicit loading state, while preview tests own ready/invalid
  behavior. Preview observers now publish the current snapshot after first layout.
- Adopted the previous WebP-safe-folder candidate plus the exact five-file
  `fixed.zip` overlay as the sole continuing baseline.
- Preserved the overlay's partial-WebP decoder fixes while replacing fixed-duration
  widget synchronization with explicit preview-state observers and controlled futures.
- Replaced the Reader app's `FakeCoordinator` with `LiveCoordinator`, real transport
  selection, `DownloadRegistry`, and promoted-artifact media loading.
- Added observer-safe `DownloadSession` snapshots, cancellable WebP byte loads, and
  explicit Reader binding detach, preventing stale promotion listeners and demand
  plans during page replacement and teardown.
- Kept Reader WebP presentation on Flutter codec until Android native texture
  lifecycle/device validation succeeds.
- Retained recursive local-folder import, natural sorting, explicit relative
  display names and single-player switching, then generalized it to header-detected images.


## 0.18.3-dev.21

- Fixed the malformed-local-WebP smoke test by giving the primary validation message a stable `webpPreviewErrorKey`.
- Changed the secondary footer status from `WebP 文件无效` to `加载失败`, so product UI no longer exposes two matching validation messages.
- Replaced the global `find.textContaining` assertion with a keyed error-widget assertion and kept the exact imported filename check.
- Added repository regression gates that reject duplicate validation status text and unkeyed malformed-WebP assertions.
- Updated workspace/native versions to the 0.18.3 baseline.

## 0.18.2-dev.20

- Replaced the platform-dependent `Future<XFile?>` picker contract with `Future<PickedWebp?>`, which carries the selected file and an explicit normalized display name.
- Fixed local-import preview titles when `XFile.fromData` reports an empty `name` in Flutter tests; route titles now receive `local.webp` and `broken.webp` from the picker result rather than re-reading platform metadata.
- Added filename fallback from `XFile.name`, URI/path basename, and finally `本地 WebP` for real system-picker results.
- Kept the stable preview route/title keys and bounded route pumping from the previous repair, while adding repository gates for display-name ownership.
- Updated the native library version and its stale Rust assertion to the 0.18.2 baseline.

## 0.18.1-dev.19

- Fixed local WebP picker widget tests by waiting for a stable preview-route marker instead of assuming one timed pump completes asynchronous picker navigation and the route transition.
- Added stable preview screen/title keys shared by production code and widget tests.
- Kept malformed-file verification separate: tests first wait for the route, then wait for the controlled validation error.
- Added repository regression gates for preview route identity and asynchronous test synchronization.
- Added a next-chat handoff document for continuing from this exact baseline.

## 0.18.0-dev.18

- Fixed the local WebP picker smoke test to use a real finite-loop fixture and added a separate malformed-file regression with a controlled in-app error.
- Added `WebpInfo` parsing for VP8X, VP8, and VP8L containers so imported bytes are validated before either codec is created.
- Added `RasterPlan` to separate the adaptive physical display target from the encoded-image decode size.
- Stopped Flutter and native paths from upscaling tiny sources during decode; small partial-frame animations now compose at intrinsic size and use nearest-neighbour rendering.
- Kept large comic pages on aligned, DPR-aware downsample targets with smooth filtering and bounded pixel budgets.
- Avoided native cursor recreation when a viewport change alters only display scale but not the actual decode raster.
- Added pure-Dart raster/parser tests and a Flutter widget regression for the partial-blend fixture.

## 0.17.0-dev.17

- Fixed the missing `DecodeTarget` import in the static demo and moved the target model into its own pipeline module.
- Added viewport/DPR-aware physical decode targets with 8-pixel alignment, aspect-preserving fit, and a four-megapixel safety budget.
- Replaced the fixed 1024-pixel Animated WebP target; native and Flutter codec paths now share the same target derived from the actual image viewport.
- Fixed Flutter codec presentation by giving the image tight expanded constraints and matching `cacheWidth`/`cacheHeight` instead of rendering at intrinsic size.
- Changed native preview playback to prepare the next frame while the current frame is visible and subtract preparation time from the encoded duration, removing decode time from the animation timeline.
- Added pause-safe pending-frame/completion scheduling, physical-target tests, and frame-pacing regression tests.

## 0.16.0-dev.16

- Bundled the three deterministic Animated WebP fixtures as real Flutter app
  assets and added a checked JSON catalog.
- Replaced the automatic static-reader launch with a demo home that exposes the
  100-page chapter, bundled Animated WebP catalog, and local WebP import.
- Added system file selection through `file_selector` 1.0.3, selected to retain
  the workspace Dart 3.6 compatibility floor.
- Added an in-app Animated WebP player that can compare the native source/cursor
  pipeline with Flutter's codec and automatically falls back when the native
  runtime is unavailable or incorrectly linked.
- Added `PixelFrame`, raw RGBA-to-Flutter image presentation, alpha
  premultiplication, finite/infinite loop playback, pause/resume, and native
  runtime provenance reporting.
- Added fixture synchronization, asset/native-byte equality gates, app entry
  tests, catalog tests, and local-import route tests.

## 0.15.0-dev.15

- Replaced the external per-ABI `ZIC_ANDROID_WEBP_ROOT` contract with a pinned
  upstream libwebp source checkout.
- Added `native/libwebp.lock` for version 1.6.0 and exact commit verification
  against the official WebM repository.
- Added host and Android CMake source builders with isolated `.deps` build and
  install trees, Android NDK ABI configuration, and a static-by-default APK link.
- Updated Android native packaging to link only source-generated libraries and
  package upstream `COPYING`, `PATENTS`, and source provenance.
- Added source-built host smoke/Rust scripts and CI coverage for all Android
  ABIs; distribution `libwebp-dev` packages are no longer used by CI.
- Made native inclusion explicit with `ZIC_ANDROID_NATIVE`; split APK builds
  include the source-built media core by default and can opt out for UI-only CI.
- Bumped the native ABI to v5 and exposed linked libwebp decoder/demux versions
  so Dart can reject an incorrectly linked runtime instead of trusting filenames.

## 0.14.0-dev.14

- Replaced the nullable `FrameCursor.decodeNext()` result with explicit
  `CursorStep.frame`, `CursorStep.needMoreData`, and `CursorStep.end` states.
- Added `CursorBinding`, so `DecodeSession` receives frame and optional loop
  capabilities with static types and no `is LoopCursor` runtime branch.
- Updated native and fake cursor factories to return typed bindings; non-loop
  EOF now enters `DecodeState.ended` instead of being confused with incomplete
  input.
- Added media/session regressions for explicit cursor states and cancellation
  disposal.
- Hardened libwebp verification by checking every byte prefix of all animation
  fixtures and adding a bytewise native cursor test.
- Added Android Rust/libwebp per-ABI packaging scripts for arm64-v8a,
  armeabi-v7a, and x86_64, with shared/static dependency layouts.

## 0.13.0-dev.13

- Added native Animated WebP frame-count, play-count, metadata-complete, cycle,
  and rewind ABI functions.
- Added explicit infinite and finite animation loop semantics. Rewind is only
  accepted after end-of-stream and finite play counts are enforced natively.
- Added `AnimationInfo` and optional `LoopCursor` media contracts.
- Updated `DecodeSession` to rewind only after held frames are consumed and to
  enter an explicit `ended` state after a finite animation is exhausted.
- Added animation-loop telemetry, a finite-loop WebP fixture, C smoke coverage,
  Rust ownership/rewind tests, and Dart session-level loop tests.

## 0.12.0-dev.12

- Replaced the native WebP cursor placeholder with real incremental Animated
  WebP decoding through libwebp partial demux.
- Decode only complete frame fragments; incomplete prefixes return
  `needMoreData` without advancing cursor state.
- Added target-size RGBA composition with WebP blend and dispose handling,
  immutable frame handles, duration propagation, and one-pass end detection.
- Added a deterministic two-frame Animated WebP fixture and Rust tests for
  complete decode, partial-prefix waiting, frame bytes, and end-of-stream.
- Added system/custom libwebp link configuration, C dependency smoke checks,
  CI installation, and repository gates.

## 0.11.0-dev.11

- Made `ReaderBinding` require explicit `Coordinator` and
  `PlaybackCoordinator` dependencies instead of deriving playback capability
  from a demand coordinator at runtime.
- Added ABI v3 native cursor create/free/decode contracts with epoch checks and
  shared source ownership.
- Added retained native frame handles with immutable metadata/data access and
  independent retain/release lifetimes.
- Added Dart `NativeCursorFactory`, `NativeCursor`, and `NativeFrame` wrappers.
- Added `SourceStatus.failed` and source-lock failure handling.
- Added reader-binding interface separation, ABI enum/version, source/cursor
  ownership, and frame-retain regression tests.

## 0.10.0-dev.10

- Replaced the stale `ReadingDirection.leftToRight` test value with `ltr`.
- Added `ReaderBinding` to drive demand reconciliation and viewport playback
  from the same reader observation, and connected the demo app to the binding.
- Added decoded-frame and renderer-output byte budgets with current-page
  reserves and low-priority non-current trimming.
- Added output byte accounting, claim-safe frame/output trimming, and frame
  budget telemetry in `LiveCoordinator`.
- Added reader-binding and frame-budget integration tests plus regression gates.

## 0.9.0-dev.9

- Removed invalid trailing commas from native source enum index expressions.
- Added split-per-ABI Android APK builds through `tool/build_android.sh`.
- Switched CI and full toolchain checks from fat APK to split APK output.
- Added viewport idle/dominant/overlap/continuous phase resolution.
- Added playback gating and coordinator integration for viewport freeze/resume.
- Added regression tests for discrete overlap, target dominance, continuous
  scrolling, and playback-gate state transitions.

## 0.8.0-dev.8

- Fixed duplicate upload work caused by source-ready and download-complete wake-ups.
- Counted renderer-owned ready output toward the decode watermark.
- Added non-cancelling lane follow-up work with per-key coalescing.
- Added explicit frame advancement; source progress alone no longer advances playback.
- Added a playback timer whose duration starts after actual present, with freeze/resume.
- Added regressions for duplicate upload, prepared depth, lane follow-up, and playback timing.

## 0.7.0-dev.7

- Imported `EncodedSource` in the frame cursor contract.
- Fixed `Artifact.readPrefix()` closing its random-access file before the
  asynchronous read completed.
- Added an immediate prefix-read/file-close regression test.
- Added renderer-owned output frame and frame uploader contracts.
- Added upload sessions and registry with upload and present claims.
- Deferred output disposal while a present claim remains active.
- Rejected and disposed stale upload results.
- Connected successful decode work to upload-demand wake-up.
- Added upload state, uploaded-frame, and presented-frame telemetry.

## 0.6.0-dev.6

- Fixed restored sniff prefixes being stored as unmodifiable lists.
- Changed artifacts to open partial writers lazily and serialize writes.
- Removed idle file handles from startup recovery and cache scanning.
- Added source-ready/source-disabled telemetry and early decode wake-up.
- Added frame/cursor contracts, frame holder claims, decode sessions, and a
  decode registry keyed by `DecodeId` and source epoch.
- Made coordinator idle detection stable across work submitted by other lanes.
- Added regression coverage for the reported session failures and decode flow.
- Copied queued byte chunks at ownership boundaries and isolated
  source-listener failures.
- Disposed frames decoded after cancellation or epoch supersession.
- Fixed coordinator upload dispatch and cancellation of detached active
  downloads during dispose.

## 0.5.0-dev.5

- Fixed the missing `DownloadSession` import in `LiveCoordinator`.
- Moved `RetryPolicy` duration validation out of const evaluation.
- Added the pure Dart media contracts, source pool, and format-aware ingress.
- Mirrored confirmed WebP downloads into native encoded sources while keeping
  artifacts authoritative.
- Rebuild encoded sources from restored partial/final artifacts.
- Added ingress and download-integration regression tests.

## 0.4.0-dev.4

- Fixed Flutter platform-generation and test working directories.
- Added explicit Flutter and Dart package test runners.
- Added cache limits, LRU planning, safe trim/clear, and released-byte reports.
- Added bounded retry/backoff for demanded failed downloads.
- Added decode, upload, and maintenance lane shells.
- Added Rust incremental byte-source ABI and Dart FFI wrapper.

## 0.3.0-dev.3

- Renamed the reserved `library` package to `catalog`.
- Added cache index, scanner, startup recovery, network lane, and live download
  coordination.
