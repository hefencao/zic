# ADR 0339：Native decode queued work 复用 scheduler TaskControl

状态：Accepted

## Context

`DecodeLane` 已经是 Reader native decode admission/rank 的唯一 scheduler owner，并通过
`CancelToken` 拥有 cancellation 与动态 numeric priority。此前 `DecodeSession` 在进入和离开
`decodeNextScheduled()` 时检查该 token，但 `ScheduledFrameCursor` 只把
`current/nonCurrent` execution class 传到 `NativeCursor`。

因此一个已经离开 DecodeLane、但仍在 native worker pool 等待 slot 的 request 有两个问题：

- scheduler cancellation 只能等它取得 worker、完成 FFI 后才被上层看到；
- scheduler numeric priority 在 native pending queue 中丢失，queue 只能在 current/nonCurrent class 内按提交顺序等待。

不能通过新增 native-side policy、PageRole gate 或更多 worker 修复这一点。native pool 只能消费
已有 scheduler fact；已经进入 FFI 的 operation 也不能因为 token cancelled 就伪装成退出。

## Decision

1. `ScheduledFrameCursor.decodeNextScheduled()` 接受可选 `TaskControl`。
   `DecodeSession` 必须把当前 DecodeLane `CancelToken` 原样传下去，`NativeCursor` 再原样传给
   native decode pool。该 control 是只读 projection，不把 scheduling authority 转移给 bridge。
2. native decode pending item 在**尚未 worker admission**时只持有原 scheduler `TaskControl`：
   - `TaskControl.whenCancelled`：移除该 queued item，并以原 typed cancellation 结算；
   - numeric rank 不再复制到 pending 字段，也不建立 request-local `priorityChanges` subscription；每次真正选取 pending 时直接读取 `TaskControl.priority`。这样 priority 的事实仍来自同一个 scheduler owner，但 bridge 不再维护第二份镜像状态和订阅生命周期。
3. native pool 仍保留两类 execution class：
   - `current` 始终先于 `nonCurrent`；
   - `nonCurrent` 在只剩一个 live worker 时不得占最后一个 slot。
   class 内只按 scheduler numeric priority 降序、submission sequence 升序选择。
4. PageRole 迁移到 current 时，`LiveCoordinator` 必须先把新的 numeric priority 写回
   `DecodeLane`，再把同一 pending native request 从 nonCurrent 迁移为 current。
   禁止用 `addFirst` 之类 native-side shortcut 代替 scheduler rank。
5. bridge 不拥有 numeric-priority observer；selection-time live read 足以覆盖 worker busy 后的动态 rank，因为真正 admission 只发生在 `_takeBestReady`。execution-class promotion仍由显式 `promotePendingDecodeToCurrent` 驱动并立即 `_pump()`，不依赖 numeric-rank subscription 触发调度。
6. **in-flight cancellation 不提前释放 capacity。** request 一旦交给 worker，cancel signal 只会让
   上层在真实 worker response 之后丢弃结果；`_activeRuns`、worker busy state 与 cursor/source
   lifetime 都必须等实际 native operation unwind。
7. 因此 source/decode generation retirement 必须等待对应 DecodeLane/UploadLane task 的真实退出。
   demand removal 可以立即 cancel lane task，但不能先 dispose 正被 admitted work 使用的 cursor/source。
8. 本决策不改变 2/1 decode window、worker count、current-only handoff slot、UploadLane、
   FrameBudgeter 或网络 7/3 policy，也不增加新的 retry owner。

## Validation contract

稳定回归必须同时覆盖：

- `DecodeSession` 将同一个 scheduler control 传给 scheduled cursor；
- queued cancellation 可以在 worker admission 前结束 pending work；
- cancellation 发生在 admitted work 后，Future 仍等待真实 operation return；
- role promotion 保持同一 request，并由 scheduler priority + execution class 决定顺序；
- source/decode generation 在 cancelled admitted task 真实退出前不会被退休；
- worker exit retirement（ADR 0338）与本 control seam 可以同时成立。

`tool/test_native_decode_control_ownership.py` 固定跨层 control、queued rank/cancellation 与
nonCurrent last-slot reservation；ADR 0338 的 worker-exit guard 继续独立验证 worker liveness owner。
