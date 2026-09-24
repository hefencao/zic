# ADR 0323：vertical active deadline static pre-presentation

## 状态
Accepted。

## 问题

2026-09-24 Profile 真机 `zic-debug-trace-2026-09-24T07-43-20.jsonl` 的 `pipeline-reader-2` 复现了连续纵排滑动时大量图片进入视口仍为空白。107 次 PageHost dispose 中有 22 次从未得到首帧；多个真实访问在第一次正 coverage 后仍需约 0.2–0.8s 才 `firstFrameReady`。同时 source artifact 多数已经是约 5–20ms 的本地 `presentation-file-lease`，native static WebP decode 约 90–120ms，却出现约 1.95–2.34s 的 `outputReadyToPresent`，说明债务位于 decode 之后的 native presentation admission，而不是下载或解码本身。

现有 `deferHiddenVerticalNativeStaticUpload` 在 dragging/scrolling/settling 期间把所有 non-visible generic/native static UploadDemand 推迟到 visible/current/transition。这个边界原本用于避免 speculative RGBA→SurfaceProducer copy 与滚动合成竞争；但 ADR 0294 已记录 dev.314 设备证据：延后 hidden next2 copy 并未消除抖动，只把第一次物理 copy 移到了 visible transition seam。最新 trace 进一步证明 blanket defer 会把已完成的 decode-ahead 变成可见区 presentation debt。

第一轮仅放开 deadline UploadDemand 后，fresh Profile `zic-debug-trace-2026-09-24T08-11-46.jsonl` 仍出现约 2.44–3.34s 的 `outputReadyToPresent`。继续沿 owner 链复核后发现更底层的结构性 gate：`PipelineReaderSession._maybePrewarmPagedOutput()` 与 plan-sync 路径显式排除 vertical，因此纵排即使 `UploadSession` 已经 ready，也没有 detached `PipelinePageOutputStream` 去 `claimPresent()/present()`；成品只能等 PageHost mount 后才被消费。`outputReadyToPresentMicros` 的定义正是 `presentStartedAt - outputReadyAt`，因此这类秒级值是 presentation admission/consumer debt，而不是 native decode 或 platform blit 本身耗时。

同一 trace 还显示首次遇到的 JPEG 页可能在 PageHost 已挂载后仍使用一屏高 provisional extent。现有 physical ingress 已能从 prefix 投影 source-canvas size，但 dev.291 的公开 metadata ABI 只有 64B；JPEG SOF 经常位于 APP/EXIF 段之后。该缺口应由 physical owner 的 bounded dimension probe 修复，而不是等待完整 Flutter decode 后再回报尺寸。

## 决策

1. vertical active presentation 期间，existing 2/1 decode deadline window 中的 `next`、`next2`、`previous` static one-frame output MAY提前建立 UploadDemand/present；这些 output MUST `retainOutput=true`，直到既有 FrameBudgeter 按 deadline/visible 生命周期裁决。
2. `far/near` hidden native static 仍属于 speculative work，在 active vertical motion 期间 MUST继续 defer；idle 后可恢复既有 3/7 one-frame static warm。该变更不是扩大预加载窗口。
3. deadline pre-presentation 不创建新的 DecodeDemand、DownloadDemand、水位或 byte budget。7/3 encoded、2/1 decode、3/7 direction classifier、idle warm 均保持不变。
4. 执行限流仍唯一属于现有 `UploadLane` 与 `FrameBudgeter`：Reader profile 的 upload lane 保持 bounded concurrency、current reservation 和 priority/preemption；不得在 Reader/UI 再加并发 gate 或第二套 presentation budget。
5. reverse motion 同样使用 `previous` deadline role。不得等待 stable 3/7 direction classifier 翻转后才开始上一方向页面的第一帧 presentation。
6. external-static Flutter raster 继续遵循 ADR 0322 的 unified presentation raster authority；本 ADR 只收紧 native static texture 的 active presentation admission，不重新耦合两条 residency owner。
7. vertical 对已经拥有 real UploadDemand 的 `current/transition/next/next2/previous` native static DecodeId MUST在 plan commit 时预绑定 detached `PipelinePageOutputStream`，使 ready output 可立即 `claimPresent()/present()`；不得等待 PageHost mount。横排既有 decode-only animated-next empty-lease 优化继续只属于 horizontal，vertical 不因此扩大 animated work。
8. dev.291 的 generation-local source-metadata prefix MUST继续保持最多64B。physical `DownloadSession` MAY在 source canvas 未解析期间另外保留最多64KiB的一次性 dimension probe，以跨过 JPEG APP/EXIF 查找 SOF；尺寸成功后 MUST立即释放该 probe。它不得成为正文缓存、Reader replay authority 或新的持久 metadata ABI。

## 被取代的边界

本 ADR 只取代 dev.281/dev.295 中“vertical active 时所有 non-visible generic/native static，包括 immediate next/next2/previous，都禁止 upload”的 blanket 部分。历史关于 hidden platform blit 与 cadence 的 trace/审计继续保留；`far/near` active defer、source-canvas authority、geometry、NetLane、decode staged refill 与 output budget 均不变。

## 验收

- fresh Profile 连续纵排正反向滚动时，以页面第一次 `targetCoverage.fraction > 0` / viewport entry 为边界；deadline static 页应已经首帧 ready，或至少不得持续形成数百毫秒可见空白；
- 不得再出现由 withheld upload 或缺失 detached consumer 形成的秒级 `outputReadyToPresent`；native deadline output 应在 host mount 前已有 output projection/首帧 presentation；
- active 计划必须包含 static `next/next2/previous` 一帧 UploadDemand 且 `retainOutput=true`，同时 `far` static UploadDemand 仍被 defer；
- 首次 JPEG 若其 SOF 位于前64KiB内，应在完整 image decode 前发布 `sourceCanvas/pageDimensionsResolved`，且公开 `sourceMetadataPrefixLength` 仍为64；
- fresh trace 需同时检查 scroll cadence，确认 deadline pre-presentation 没有恢复无界 speculative platform copy；
- 全仓治理、Pipeline/Sessions tests、Android/Profile 构建必须通过。

## 2026-09-24 Profile 复核

fresh Profile `zic-debug-trace-2026-09-24T08-55-17.jsonl` 使用同一漫画连续正向滚动并反向消费 `previous`。同口径统计中，16 次跨页访问没有任何一次在首次正 viewport coverage 后才 `firstFrameReady`；唯一 `pageCurrent` 前未 ready 是 Reader 初始 page20 启动首帧，mount→ready 约130ms，不属于滚动可见空白。

3 个被记录的 native `framePipelineTiming` 样本中，`outputReadyToPresentMicros` 为53/53/88µs，主导阶段全部回到 `nativeDecode`，约100–109ms。相比 `08:11:46` 的 p95 约2.44s、最大约3.34s，秒级 presentation admission debt 已消失。

纵排 detached output 在真实 plan 中已提前创建：page27/28/29/30 分别在 host mount 前约402/310/455/510ms完成 `pageOutputPrewarmed(created=true, detached=true)`，随后 mount→first-frame 约33/17/33/33ms。`far/near` 窗口没有因此扩大。

source-canvas size 也继续前置：例如 page28 的1080×3600尺寸由 `physical-ingress-source-canvas` 在 host mount 前约6.39s发布；focused JPEG 回归证明 SOF 位于64B之后时仍可由一次性 dimension probe 得到1080×3600，同时公开 metadata prefix ABI 仍为64B。全仓 `tool/check.sh --require-toolchains` 与 Profile 构建均通过。
