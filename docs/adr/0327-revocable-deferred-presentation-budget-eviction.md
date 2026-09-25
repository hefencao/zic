# ADR 0327：可撤销的 deferred presentation budget eviction

**Status:** Accepted

## 背景

ADR 0322/0324 已经规定 `PipelinePresentationRasterCache` 是 Reader external-static raster 的唯一 residency/LRU owner：`far/detached` 为 `speculative`，`next2/next/previous/near/last` 为 `deadline`，真实 viewport/current/transition 为 `protected`；预算压力只能回收 speculative raster。近期为避免 cache 维护工作抢占 UI frame，budget trim 先从 managed active set 撤销 speculative entry，再把 `keepAlive.dispose()`、generic Flutter `ImageCache` cleanup 与 exact invalidation 延后到 idle maintenance。

第二台真机 `210a3115` 的实际手滑 trace `zic-debug-trace-2026-09-25T11-22-11.jsonl` 暴露了这个两阶段协议缺少撤销边界。`pipeline-reader-9` 是《全开放群聊》“第11話 11”的 42 页静态纵排章节；ScrollPosition cadence 持续约 8.4ms，并不存在每四五页一次的滚动坐标停顿，但 50 次 page-current 迁移中出现 85 次 presentation-raster invalidation，其中 12 次在 invalidation 真正送达时 identity 已经晋升为 `next2`/`transition` 且 `presentationWarmAllowed=true`。也就是说旧的 speculative 淘汰决定在 idle 物理释放前已经失效，却仍释放刚成为近页的同一 raster，随后 Pipeline 又立即请求相同 presentation generation。

## 决策

1. deferred budget eviction 在 physical cleanup 真正执行前只是**可撤销的 speculative eviction intent**，不是不可逆的 raster destruction。
2. `updatePresentationClaim()` 将同一 `presentationIdentity` 从 speculative 晋升为 deadline/protected 时，如果该 identity 仍在 pending physical eviction 中，cache owner 必须收回原 `_PresentationRasterEntry`、恢复同一个 managed `keepAlive` 与精确 byte accounting，并取消对应 pending budget invalidation。
3. reclaim 不创建第二个 provider/cache identity，不重新 decode，不复制 RGBA，也不让 Pipeline 保存 tombstone。角色/需求仍只由 Pipeline 投影，是否撤销尚未执行的 cache eviction 仍由 presentation cache owner 决定。
4. 该规则不扩大 100MiB/1000-entry envelope，也不改变 3/7 encoded window、2/1 deadline window、NetLane、decode/upload waterline 或 Reader ScrollPhysics。若 reclaim 后仍超预算，owner 继续按既有规则淘汰其他 speculative entry；deadline/protected 仍按 ADR 0322 的既有合同保持 pinned，待其降回 speculative 后才重新成为 victim。
5. explicit generation invalidation、memory-pressure clear 与已实际执行的 physical eviction 仍不可被该路径“复活”。本 ADR 只允许在 idle physical cleanup 前撤销同一 generation 的 stale speculative budget decision。

## 验证

加入 owner-level 回归 `deadline promotion rescues a deferred speculative budget eviction`：在 `maximumEntries=1` 下让 speculative entry 被 budget 选中但尚未 idle cleanup，随后把同一 identity 晋升为 deadline；期望仍存活的 managed entry 被直接收回，idle drain 后不发送 stale invalidation，也不重新 decode 同一 raster。`presentation_raster_cache_test.dart` 6/6 通过；`media_runtime_ownership_test.dart` 30/30 通过；dev.114 vertical visibility/staged static presentation contract 通过，目标文件 analyzer 无问题。

修复后的标准 Profile 重新安装到同一 `210a3115`，再次进入同一 42 页章节并以生产 ScrollPhysics 正常速度从 page 13 前进到 28、再回到 22。新 trace `zic-debug-trace-2026-09-25T11-37-31.jsonl` 有 38 次 budget invalidation，全部仍是合法 `far/none` 且 `presentationWarmAllowed=false`；修复前的 12 次 `next2/transition + allowed=true` 降为 **0**。没有 `taskFailed`、`writerRejected` 或 `sourceDisabled`，最大 Pipeline reconcile 为 1.632ms。稳定滚动 summary 中位 frame gap 约 8.402ms；仅 Reader 初段 page14 出现一次 34.289ms gap，后续没有形成原先“数页一次”的周期模式。

`external_presentation_generation_test.dart` 当前工作区的两个 widget 用例仍超时；对本 ADR reclaim hunk 做临时撤销 A/B 后仍以相同位置、相同方式失败，因此不是本变更引入，未为通过旧测试而恢复错误的 production eviction 生命周期。

## 非目标

- 不提高 presentation cache 大小；
- 不新增 Reader/Pipeline 私有 cache、revalidation 或 retry；
- 不改变静态纵排滚动物理、速度、阻尼或手势；
- 不把 cache cleanup、decode、download 或 source authority 移回 Reader；
- 不用更远预热来掩盖近页被错误淘汰的问题。
