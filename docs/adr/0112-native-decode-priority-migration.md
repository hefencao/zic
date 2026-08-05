# ADR 0112：Native Decode 排队优先级迁移

**状态：Provisional**

## 背景

页面进入预解码窗口时，`DecodeSession` 根据当时的 `PageRole` 将 native 请求提交为 `current` 或 `nonCurrent`。外层 `DecodeLane` 支持 demand priority 更新，但 native worker pool 中已经排队的请求仍保留最初 execution class。

设备 Trace 证明，完整 source 已提前 ready 的页面可能以 `far/nonCurrent` 排队，并在页面升为 current 后继续饥饿。外层 task 仍在等待同一个 native Future，因此再次提交 current demand 不能替换或提升该 native 请求。

## 决策

- `media` 提供窄能力 `PrioritizableScheduledFrameCursor`，只允许把当前正在等待的请求提升为 current。
- `NativeCursor` 按 cursor address 与 source epoch 请求 native pool 原位迁移。
- queued nonCurrent 请求保留原 completer、Future、cursor、epoch 和排队时间，移动到 current 队首。
- 已经 active 的 native call 不强制中断，只把 worker execution class 更新为 current；本次有界 native call 完成后继续正常 staged refill。
- `LiveCoordinator` 在同一 DecodeId 的 demand role 升为 current 时立即触发迁移，即使外层 DecodeLane task 仍 active。
- worker pool 首次启动期间的请求先登记，两个 worker 全部 ready 后统一开始调度，避免 isolate 启动完成顺序改变 current/nonCurrent 选择。

## 不做

- 不增加 native worker 数量。
- 不取消并重建 cursor。
- 不修改 7/5/3/2 水位、启动缓冲或静态单帧满足规则。
- Reader 不获得 native worker、cursor 或 decoded frame 所有权。

## 验证状态

源码、owner tests 与静态合同已实现；等待 Flutter/Dart 与设备 Trace 验证。下一份 Trace 应出现 `decodePriorityPromoted`，并确认页面升为 current 后迅速产生 frame 0。
