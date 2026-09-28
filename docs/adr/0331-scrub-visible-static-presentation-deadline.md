# ADR 0331：Scrub 可见集合与有界静态 presentation deadline 对齐

状态：Accepted

## Context

ADR 0329/0330 已把 slider scrub 的导航 membership 与资源执行深度拆开：Reader 仍保留前7/后3 logical working set，
scrub 只允许真实 current/visible 页面做 local-only 一帧工作，hidden identity 不得开启远程传输。
随后 held-slider 真机结果又修复了 unknown vertical ratio 把相邻真实可见页挡在 geometry 之外的问题。

最新问题发生在这一边界之后：拖动时 `visibleIndexes` 已正确包含 current 前后的页面，但前后页的 representation 仍通常晚于 current。
Profile Trace 证明 local durable restore 本身只有数毫秒，主要偏移出现在 staged decode / external-static presentation 交接。

对照当前 Mihon 实现后，关键不是扩大并发。Mihon WebGPU decoder 本身是单线程；
连续模式的差异在于 viewer 把真实 viewport 与紧邻页放在同一 page cache / decode lifecycle 中，
并明确要求屏幕内页面必须 decoded 而不是仅 reserved。旧 Webtoon holder 也会在页面真正绑定后把它从 adjacent preload 提升为正常 page load。
也就是说，`current` 是导航/进度语义，不是唯一 representation deadline。

ZIC 还存在三处不一致：

1. `StagedDecodeRefillPolicy` 把 `PageRole.transition` 当成单例，短页同时露出前后两页时其中一个真实 visible transition 可能被覆盖。
2. Android texture output prewarm 在 frame busy 时只让 current 立即创建 lease，vertical 已真实可见 transition 仍被推到 idle。
3. External-static decode 已结束并把一帧交给 presentation owner 后，`externalPresentationPending` 仍被当作“decode 未满足”，
   会阻塞同一现有 deadline 窗口中的下一项静态一帧 warm。结果是相邻页虽然已有本地 authoritative bytes，
   也常要等 current 的 mounted first-frame acknowledgement 后才开始 representation。

## Decision

1. `transition` 是可重复 viewport role，不是 singleton target slot。
   Staged first-frame refill MUST 在所有 transition demand 中选择当前可执行的一项；
   某个 transition 等 source/presentation 时不得遮蔽另一个真实可见 transition。
2. Continuous vertical 中 `UploadDemand.viewportVisible=true` 的页面与 current 共享 first-frame output-prewarm deadline。
   若 exact output host 尚未拥有 resident surface，可在当前 control turn 预建同一 SurfaceProducer lease；
   horizontal PageView transition 继续保持原 idle handoff，避免把未真正绘制的 target 当作当前 viewport。
3. Scrub 仍不扩大 7/3 membership，也不恢复 hidden remote work。但现有 static presentation deadline `next / next2 / previous` MAY 在 `transientPreview` 中取得：
   - `EncodedWorkMode.localOnly`；
   - 单帧 `DecodeDemand.targetWatermark=1`；
   - `UploadDemand.prepareOutput=true`。
   资格只来自现有 RoleWindow + static evidence/inference；`localOnly` 不得打开 remote source。外层 `near/far` 继续 `retained + targetWatermark=0 + prepareOutput=false`。
4. External-static decode 一旦 `DecodeState.ended` 且已产生 `externalPresentationPending`，对 staged **decode** 排序视为已满足：
   等待 mounted/detached first-frame acknowledgement 属于 presentation dependency，不再占据 decode refill 前驱。
   实际 offscreen presentation handshake 仍由 `maxSpeculativeExternalPresentationPending` 独立有界，visible/current 仍可抢占；
   不得因此建立第二 scheduler 或无限 detached raster work。
5. Composition 的 `PipelinePresentationRasterCache` 继续是 external-static raster 唯一 residency owner。
   提前准备的 exact identity 后续进入 viewport 时必须直接复用 prepared raster；
   不得复制到第二 cache，也不得重新解释为网络预取。
6. ReaderController 的 50ms latest-wins slider navigation 保持不变。它控制 viewport command 频率，不是 presentation preload window；不得为了追求“同步”把 pointer-rate 每个页号都提交到 Pipeline。

## Evidence

在同一台 Profile 真机和同一静态竖排工作负载上，修复前 `adjacent firstFrameReady - current firstFrameReady` 的匹配样本为 n=75，median 16.1ms、p90 48.7ms、max 82.1ms，80% 为 adjacent 更晚。

完成 transition 多实例、vertical visible prewarm、2/1 local-only static deadline 与 decode/presentation dependency 分离后，
最新 Profile 样本 n=32 的 median 为 0.0ms、p90 29.9ms、max 32.2ms，adjacent 更晚占 53.1%。
Trace 中可见大量 `external-presentation-first-frame owner=detached-image-cache preparedOnly=true`，
随后 viewport mount 以 `external-presentation-visible-first-frame prepared=true` 复用；未见 `taskFailed`。

该结果证明主要的 current-vs-adjacent representation 偏置已从 owner/scheduler 边界移除。
剩余尾部约两帧属于尚未提前完成的真实 raster/present 成本；在没有新的证据前，不扩大 speculative presentation 并发或 7/3 工作窗。
