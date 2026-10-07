# ADR 0324：external-static 单一 residency / admission owner

## 状态
Accepted。

## 问题

2026-09-24 fresh Profile `zic-debug-trace-2026-09-24T09-01-07.jsonl` 继续复现“滑动一快就空白”。上一轮 ADR 0323 已把 native `outputReadyToPresent` 从秒级压到微秒级，本次 trace 中 native decode 仍约 85–105ms，因此旧 native presentation debt 未回归。

新的 fast-scroll 缺口位于 external-static Flutter raster。page36 的 detached first-frame 在首次正 viewport coverage 前约 554ms 已 prepared，但 mounted frame 仍晚约 66–82ms。进一步沿 Flutter 实现与当前 owner 链核对后确认存在两个相邻但独立的权威裂缝：

1. mounted `MediaRasterImage` 最终仍使用 Flutter `Image`。`Image` 会自动套 `ScrollAwareImageProvider`，它只询问 Flutter 全局 `ImageCache.containsKey()`，看不到 `PipelinePresentationRasterCache` 已经准备好的 managed raster，因此高速滚动时会再次调用 `recommendDeferredLoadingForContext()`，形成 Pipeline 之后的第二套 presentation scheduler。
2. `Image` 在 `TickerMode(false)` 下拿到 frame 后会停止 listener 但保留 stream keepAlive。Reader keepAlive/composition shell 因此可能在统一 cache owner 已释放自己的 keepAlive 后继续把同一 completer/raster 留活，使“owner 已 eviction”与“实际 mounted consumer 仍持有”不一致。

原先 `_externalPresentationEvictedWhileFar` 又在 Pipeline 层镜像了 cache owner 的一次 budget eviction，用 tombstone 阻止 far raster 立即重建。这是典型的跨 owner 补偿：回收者不拥有 re-admission backpressure，Pipeline 只能猜测它何时允许再 warm。

## 决策

1. `PipelinePresentationRasterCache` 是 Reader external-static raster 的唯一 residency、LRU 与 admission-backpressure owner。
2. detached prewarmer 与 mounted `MediaRasterImage` 继续使用同一 raster-key policy 和同一 managed provider。
3. managed Reader static mounted consumer 不再经过 Flutter `Image`。它直接 resolve 已 manager-wrapped provider，监听到第一张 static frame 后立即移除 stream listener，只持有当前 `ImageInfo` 作为屏幕呈现引用。这样：
   - 不再触发 `ScrollAwareImageProvider` 的二次滚动 defer；
   - 不再由 `TickerMode` / `Image` 建立 private completer keepAlive；
   - mounted consumer 不成为第二个 offscreen residency owner。
4. Pipeline 撤销 external presentation permission 时，`LocalImagePlayer` 必须移除 managed raster subtree 并释放当前 `ImageInfo`。encoded provider/carrier 保留，因此以后同 generation 重新获得 exact grant 时无需重新读取正文。
5. budget trim 仅可回收 `speculative` claim。cache owner 在因预算回收 speculative raster 时，同时对同 presentation identity 设置 speculative re-admission denial；只有 claim 升级为 `deadline` 或 `protected` 才解除。
6. `clearPresentationRasters()` / memory pressure 只清 residency，不是 demand-generation 边界：现有 claim 必须保留；被 clear 的 speculative identity 同样进入 owner-side admission denial，而 deadline/protected 可按现有 demand 恢复。
7. Pipeline 删除 `_externalPresentationEvictedWhileFar`，不再镜像 eviction tombstone，也不通过 ImageCache 状态轮询/被动 revalidation 猜测 owner residency。
8. eviction/demand gap 仍不是 presentation-generation 边界。`externalPresentationCacheIdentity` 必须保持稳定；source/recovery/force-reload/fit 等真实 generation 变化才可旋转 identity。
9. 现有 7/3 encoded、2/1 deadline、idle 3/7 warm、6-screen composition bootstrap、`current±7` keepAlive、100MiB/1000-entry presentation envelope 都不扩大。

## 清理结果

本 ADR 明确删除/禁止以下历史补偿模式：

- Pipeline `_externalPresentationEvictedWhileFar` tombstone；
- mounted managed static 通过 Flutter `Image` 获得第二套 scroll-aware scheduling；
- mounted managed static 通过 `TickerMode(false)` 留下第二个 completer keepAlive residency owner；
- 用 presentation identity rotation 模拟普通 cache eviction / demand gap；
- Pipeline 轮询 Flutter `ImageCache` 或用角色提升做被动 cache revalidation。

以下状态继续保留，因为它们不是第二个 residency owner（ADR 0336 收紧了第一项语义）：

- `_externalPresentationAttemptIdentity`：仅去重当前 residency grant attempt；cache-owner revocation 必须清空，因此 same generation 可再次 grant；
- `_externalPresentationPrewarmFailures`：当前 generation 的失败隔离，防止坏 provider/codec 热循环；
- `_externalPresentationVisibleFrames`：首个 visible frame trace/投影去重；
- `externalPresentationRequested/Ready`：Pipeline exact permission 与 scheduler satisfaction fact；不是 byte proof、mutation authority 或 residency owner。

## 回归要求

- cache owner 因预算淘汰 speculative raster 后，`allowsPresentationWarm(identity)` 必须保持 false，直到 claim 晋升为 deadline/protected；Pipeline 不得另存 tombstone。
- 已 detached-prewarm 的 managed raster 在 `TickerMode(false)` 下挂载后，底层 Flutter `ImageCache` provider key 不得保持 live/keepAlive；统一 manager entry 必须仍 resident。
- ordinary presentation demand gap 必须保留同一 generation identity，同时 mounted raster subtree 被移除；重新 grant 后不得重新读取 encoded bytes。
- fit-width long-page detached prewarm 与 mounted attach 必须同步命中同一 managed raster；不能因去掉 Flutter `Image` 而改变 raster key。
- fresh Profile 高速正反向滚动必须验证：已 prepared external-static 不再在 viewport entry 后补 frame；不得用扩大预加载窗口或 cache budget 达成。

## 2026-09-24 Profile 复核

新的 Profile 在同一“全开放群聊”章节上以约140ms swipe、约50–60ms手势间隔连续正向、立即反向、再正向滚动，明显快于上一轮240ms + 260ms间隔。两轮 fresh trace 分别为 `zic-debug-trace-2026-09-24T10-39-54.jsonl` 与 `zic-debug-trace-2026-09-24T10-46-35.jsonl`。

第二轮 `pipeline-reader-2` 中，page30–38 每页第一次正 viewport coverage 之前都已有 mounted external-static frame；首次进入时的 frame lead 分别至少约983ms–20.5s。整个高压窗口共98个 external-static 正 coverage 样本，最近一次 mounted frame 到 coverage 的最小 lead 仍为约431.2ms，没有一例在 viewport entry 后才补 mounted frame，也没有 PageHost 在未获得首帧的情况下退出。

旧 `09-01-07` 中最明确的 page36 回归是 mounted frame 晚于首次正 coverage 约66.6ms；新高压复核中 page36 的 mounted frame反而提前约1154.1ms。两张快滑进行中的真机抓屏也保持完整漫画内容，没有复现整段空白。

cache invalidation 现在统一报告 `presentationWarmAllowed=false`，由 cache owner 对 speculative re-admission 施加 backpressure；Pipeline 不再存在 `_externalPresentationEvictedWhileFar`。新 trace 中仍有真实 budget eviction，但没有形成随后的 viewport-late frame，说明回收与 deadline promotion 已由同一 owner 闭环。
