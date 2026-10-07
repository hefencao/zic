# dev.120 定向预加载 Source Wake 审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.119_prefetch-wake-static-output-retention.zip`
- 设备证据：`zic-debug-trace-2026-08-04T08-37-18(1).jsonl`

## 设备事实

- disposed 与静态 output 驻留方向明显改善，Trace 出现多次 `staticFrameKept`，普通 demand gap 不再立即释放静态 output。
- 预加载解码仍依赖角色变化：页面正文已经 source-ready，但第一帧延迟数秒至数十秒。
- 由 source identity 与 `mediaClassified.pageIndex` 对齐得到：
  - page 7：4.078 秒；
  - page 11：22.970 秒；
  - page 12：22.980 秒；
  - page 13：25.228 秒；
  - page 14：25.245 秒；
  - page 5：43.038 秒；
  - page 6：39.531 秒。
- page 11 在 revision 3 已拥有 `targetWatermark=1` 的 far decode/upload demand，并进入 `waitingSource`；正文在约 89.979 秒 ready，直到约 112.923 秒角色提升后才出现 `decodeRefill one>0`。

## 根因

`LiveCoordinator._runDecode` 即使由某个 DecodeId 的 source listener 唤醒，仍先调用全局 `_nextDecodeRefill()`。全局选择其他 DecodeId 时，本任务被重定向并返回。revision 虽未消费，但没有保证原 DecodeId 再次获得任务；其 pending task 还可能被普通 follow 覆盖。

此外，`sourceWake` 在任务提交时计算，任务排队期间 source revision 可能变化，执行时仍使用过期布尔值。

## 所有权

- source listener、revision 和 lane 提交：`sessions/LiveCoordinator`。
- staged target：`sessions/StagedDecodeRefillPolicy`。
- 页面窗口和 demand：`pipeline`，本轮不修改。
- output 驻留：沿用 dev.119，不修改。

## 实现

- `_runDecode` 在执行时计算 `pendingSourceWake = available > consumed`。
- `_nextDecodeRefill` 增加可选 `only`，通过 eligibility 限定候选，不复制 staged 水位算法。
- pending source wake 使用 `_nextDecodeRefill(only: id)`；普通工作继续调用全局版本。
- directed refill 实际 fill 后才消费 source revision。
- Trace 与 analyzer 增加 source-wake refill 计数和 revision 字段。
- owner test 阻塞 current cursor，在 current 释放前向 prefetch 注入 source；prefetch 必须独立完成 frame 0。

## 拒绝方案

- 不重新引入 visible role。
- 不扩大静态固定水位。
- 不让 source listener 绕过 decode lane。
- 不用周期性 timer 扫描 waitingSource。
