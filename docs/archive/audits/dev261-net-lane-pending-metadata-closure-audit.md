# dev.261 根因审计：NetLane pending metadata 构造未闭合

## 设备/编译事实

用户本地 Dart 编译直接失败于 `packages/sessions/lib/src/net_lane.dart`：`_Pending.retainFlowResponse` 已在 dev.260 变为 required named parameter，但 `_Lane.replace()` 与 `_Lane.follow()` 仍沿用旧的直接 `_Pending(...)` 构造，未传该字段。该问题发生在编译期，与 09:00 Trace 的 warm-response 策略效果无关。

## 根因

NetLane 的 queued task metadata 已逐步包含 priority、bucket、preemptible、flow target 与 warm-response bit，但 pending entry 仍存在 `submit / replace / follow` 三处独立实例化。dev.260 只修改了 ranked submit 主路径，因此公共 metadata schema 与旁路构造发生漂移。

根因不是 `retainFlowResponse` 应该可空，也不是 replace/follow 应获得 Reader warm policy；根因是 `_Pending` schema 有多个生产构造 owner。

## Owner 与修复

- `_Lane._createPending()` 成为 production 唯一 `_Pending` 实例化点，统一 sequence 与 high-priority dwell 初始化。
- `submit()` 显式传入 ranked flow metadata。
- generic `replace()/follow()` 只使用统一默认 `preemptible=true / flowTargetFrames=0 / retainFlowResponse=false`；Decode/Upload/Maintenance 不因此获得 Reader warm-response 语义。
- 既有 Dart replace/follow tests 增加 CancelToken 默认 flow metadata 断言；dev.261 静态 gate 要求 `_Pending` 只有一个 production 实例化点。

## 拒绝方案

- 不把 `retainFlowResponse` 改回 optional/nullable 来掩盖漏接。
- 不在两处调用点机械补 `retainFlowResponse:false` 后继续保留三套构造。
- 不扩展 `TaskLane.replace/follow` 公共 API 暴露 Reader flow policy。
- 不修改 dev.260 的 3/7、5/3/2/1、adjacent warm response 或 NetLane normal5+reserved1。
