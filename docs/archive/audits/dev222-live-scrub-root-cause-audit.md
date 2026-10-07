# dev.222 live scrub 根因审计

## 输入证据

输入：`zic-debug-trace-2026-08-11T11-35-28.jsonl`。

### dev.221 已闭合的主要故障

- 本 Trace 共有 56 次 page host dispose，仅 6 次 `firstFrameReady=false`，其生命周期约 0.07–0.64 秒；没有 dev.220 那类持续 6–9 秒的长期黑页。
- `decodeState` 没有 `failed`；仅有正常的 `waitingSource/decoding/ready` 流转。
- 未再出现相邻逐字段相同的 physical Trace，说明 dev.220 shared sink fan-out 去重在本轮证据中成立。
- 因此不再修改 resident replay、physical trace hub、NetLane 或 retry。

## 剩余问题：release-only scrub 破坏实时 navigation

dev.220 把 `_ReaderPageScrubber.onChanged` 改成只更新 `_previewIndex`，真实 `ReaderController.requestPage` 只在 `onChangeEnd` 执行。Trace 中 Reader3 从 page 87 直接跳到 228，resource plan只在最终 commit 后建立；拖动过程不存在 Reader page current 的连续反馈。这与用户要求的实时 slider 翻页不符。

问题不在“是否应该实时导航”，而在过去把实时 navigation 与完整 resource window 放在同一频率：dev.219 一次 slider sweep 会让每个中间 index 都形成完整 RoleWindow，造成 11-download / 4-decode / 4-upload 的反复 remove/add。

## 收口

- UI 不再自己假装 preview；每个有效 slider index 进入 Reader-owned scrub navigation，PageView/纵向 viewport立即跳转。
- Pipeline 只通过 `ReaderObs.interaction=scrubbing` 得知这是连续 scrub；RoleWindow 在该阶段只包含 current。
- Reader→Pipeline 仍经过 dev.219 的 latest-wins microtask observation queue；UI navigation 可以实时逐帧推进，而尚未 reconcile 的旧 scrub observation 会被更新位置覆盖，不引入固定毫秒 debounce。
- 中间页因此最多形成 1 download + 1 decode + 1 upload foreground demand，不生成邻域 prefetch。
- `onChangeEnd` 结束 scrub，并强制最终页再发布一次非-scrub observation恢复完整窗口；即使最终 page request已被 acknowledge，也不能漏掉该 planning boundary。

该方案把“导航频率”和“预下载窗口频率”从语义上拆开，而不是靠固定毫秒 debounce 或禁止实时翻页。
