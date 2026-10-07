# dev.128 Native Decode 优先级迁移审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.127_startup-buffer-refill-closure.zip`
- 设备证据：`zic-debug-trace-2026-08-04T15-47-56.jsonl`

## 问题分类

### 产品问题

- 已完整下载并进入 7/3 窗口的页面，在成为 current 后仍可能整个生命周期没有 frame 0。
- 后台 retained output 能立即显示旧帧，但 current 动画可能一直没有 authoritative successor，表现为播放停滞。

### 调度问题

- Decode demand 的 role/priority 会从 far、next 迁移为 current，但已经提交到 native worker pool 的请求保留最初的 `nonCurrent` execution class。
- 外层 DecodeLane 的同 key task仍处于 active、等待 native Future；后续 `follow` 只能更新外层 pending，无法提升已经排队的 native 请求。
- Native worker pool 永远优先 current queue，nonCurrent 又最多只使用一个 worker，因此旧 nonCurrent 请求可长时间饥饿。

### 测试问题

- dev.126/127 测试只覆盖 staged refill 闭合，没有覆盖“native 请求以 far 入队后页面升为 current”的跨层优先级迁移。

## 证据

- page 9 source 在成为 current 前约 3.7 秒已完整 ready/promoted，但 current 生命周期结束时仍 `firstFrameReady=false`。
- page 9 的 decode 请求最初以 far role 启动，随后 demand priority 升到 1000，但没有 frameDecoded。
- page 7 恢复 retained frame 后在 current 期间无 successor；旧 decode 直到页面变为 previous 才实际完成。

## 所有权

- 页面 role 与 DecodeId priority：`pipeline` / `sessions/LiveCoordinator`。
- native worker queue、execution class 和排队请求迁移：`bridge/native_decode_pool`。
- cursor 对 worker priority migration 的能力边界：`media` 抽象、`bridge/NativeCursor` 实现。
- Reader 只消费输出，不参与 decode worker 调度。

## 拒绝方案

- 不继续扩大 startup buffering target 或修改 7/5/3/2 水位。
- 不恢复 visible-page demand 补丁。
- 不通过增加 native worker 数量掩盖 nonCurrent 饥饿。
- 不取消并重建同一 cursor；优先级迁移必须保留原 Future、cursor epoch 和已增长 source。
- 不让 Reader 直接调用 native worker 或保存 decoded frame。

## 计划

1. 给 scheduled cursor 增加“提升当前请求为 current”的窄能力。
2. Native worker pool 按 cursor identity 将 queued nonCurrent request 原位迁移到 current queue。
3. Decode demand role 升为 current 时，即使外层 task仍 active，也立即调用该迁移能力。
4. active native 调用不强制中断；最多等待当前一次有界 native call 完成。
5. 增加跨层 owner test、Trace 事件和 analyzer 指标。
