# ADR 0167：按真实 Receiving 状态处理 Logical Detach 与 Current/Previous 交棒

## 状态

Accepted。取代 `LiveCoordinator` 中“`activeRun` 即可视为 retained receiving”的实现近似；ADR 0160 的核心语义“已 receiving 的短时 detach 不重开、queued/未建立传输可取消”保持不变。

## 证据

`zic-debug-trace-2026-08-09T08-58-13.jsonl` 显示两类事实同时成立：

1. previous policy 没有丢失。current 17→16 时，相邻 previous identity 从 priority 660 提到 780；但它约 3.00 秒后才真正 `downloadStarted`。
2. 至少多次出现 `demandDetached.receivingRetained=false` 后，同 identity 仍被 `LiveCoordinator` 以 active `retained-background` 降到 priority 0。说明 execution retention 使用的不是 session 已记录的 receiving 事实。

源码确认 `DownloadJob.run()` 在 restore 之前就 `beginRun()`；因此 `activeRun` 覆盖 restore、source request-plan、Venera runtime gate、HTTP open，以及真正 receiving。它只能表达“已有执行 lease”，不能表达“已有值得保留的接收流”。

VibeVenera继续作为只读调度参考：其窗口仍把后向下载/解码作为稳定邻居工作，running task取消后也必须等真实异步退出才释放 scheduler permit。ZIC额外存在 source request-plan/Venera单 invocation嵌套瓶颈，因此必须用自身权威 `DownloadSession.state` 区分是否已经建立 receiving，而不能只看外层 run lease。

## 决策

1. page-window logical detach 后，只有 `session.state == DownloadState.receiving` 且对应 NetLane task仍 active 时，才迁移为 `retained-background=0`。
2. task已 active 但 session尚未 receiving 时，调用同一 NetLane 的 `cancel(taskKey)`；TaskControl继续贯穿 cache/source/runtime/HTTP，真实任务退出前 permit仍被占用，不能提前伪释放。
3. task仅 queued 时继续 `cancelQueued(taskKey)` 并清理 tracking。
4. receiving task短时离开再返回仍原位恢复 priority，不建立第二 writer/transport。
5. previous priority继续为780；本轮不提高数值、不增加 normal network并发、不缩 encoded 7/3，也不增加 Reader/App scheduler。

## 后果

- current handoff不再被“尚未接收字节却被当作 retained receiving”的旧任务长期拖住。
- adjacent previous能在失去 demand 的 queued/opening工作真实退出后更快继承普通 network/runtime permit。
- 已经 receiving 的大文件仍保留 VibeVenera式短时往返复用，不退化为每次离窗 cancel/reopen。
