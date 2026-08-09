# dev.186 Venera Request-Plan 压力与 Source-Open 长尾根因审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.185_adjacent-previous-pressure-preemption.zip`
- 设备证据：`zic-debug-trace-2026-08-09T10-05-26.jsonl`
- 只读参考：`vibevenera-master.zip`

## 结论

dev.185 后外层 NetLane 的 previous admission 已基本收敛；剩余明显长尾已经下沉到 origin open 内部，最可疑的是 ZIC 为 Venera WebView 安全额外存在的 **单 invocation request-plan gate**。本轮不再修改 NetLane、7/3、2/1、5/3/2、780/1000 或 rhttp framing，而是在该嵌套 owner 上补齐与外层一致的 normal-pressure 语义，并把聚合 `openMicros` 拆成 request-plan 与 host-open 两段。

## Trace 证据

### 1. Previous 外层 admission 已从秒级降到毫秒级

可完整匹配的 5 次 inactive previous 660→780 到 `downloadStarted`：3.093 / 14.354 / 13.596 / 5.034 / **6.508 ms**，中位 6.508 ms。说明 dev.185 的 `pressurePreemptionPriorityFloor=780` 已产生预期效果；继续提高 previous rank或让它借第6槽没有证据基础。

### 2. Origin open 仍为秒级且呈 rank 队列特征

按 `downloadStarted` 时 priority 分组，启动到 `artifactSource(source=origin)`：

- 1000：5样本，中位 2,413.0 ms，范围 1,911.6–2,872.5 ms；
- 820：4样本，中位 3,267.7 ms；
- 800：5样本，中位 6,172.0 ms；
- 780：6样本，中位 **5,133.8 ms**，最大 7,747.6 ms。

这不证明 HTTP 本身一定慢，因为旧 trace只给一个 `openMicros`；但在外层 admission 已毫秒级后，低 rank仍系统性更晚获得 origin response，与嵌套 priority gate等待相符。

### 3. 不把 cancellation 误判成物理 abort 数秒

本 trace 中若只看 `sourceRead completed=true` 与后续 `Failure(cancelled)`，容易误认为底层取消后仍读数秒。逐 identity 对齐后，多个 detach/cancel发生在对应 stream自然结束前仅数到数十毫秒，当前证据不足以证明 rhttp abort 存在新的多秒泄漏。因此本轮不改 rhttp cancel/framing，而先拆阶段数据。

## 源码审计

`ExternalPluginRuntimeSession` 对 Venera 固定 `maxConcurrentInvocations=1`；`_RuntimeInvocationGate` waiter会读取实时 `TaskControl.priority`，permit transfer本身已有 priority排序，但 active preemption 仅接受 `currentPriorityThreshold=1000`。所以 previous=780 即便已在 NetLane 获槽，也只能在 Venera gate后等待 active 低 rank request-plan结束。

这与 dev.185 外层缺口同构。安全修复不是增加 Venera并发，而是把 active controlled preemption floor扩到780，并继续要求40分差值、`preemptRequested`单次请求以及旧 invocation物理退出后才转交唯一 permit。

`ArtifactCacheTransport` 当前记录的 origin `openMicros` 覆盖整个 fallback `openControlled()`；`_SourceResourceTransport` 又把 `_resolve()` 与 `_openDirect()` 包在同一调用内，因此 trace无法区分 JavaScript/request-plan等待和 rhttp response-open。新增 response diagnostics 只用于 telemetry，不进入 scheduler/cache/retry条件。

## VibeVenera 对照

VibeVenera在单图请求附近解析 image loading config，然后进入直接媒体 transport；其 scheduler允许 stronger work对低 rank running work施压，同时取消中的任务直到异步清理完成才释放容量。ZIC 的 WebView 单上下文 gate是自身实现约束，不能机械复制成并发 JS；本轮只迁移“priority pressure + physical release”结构原则。

## 修改边界

- `plugin_host`：Venera controlled preemption floor=780；仍单 invocation。
- `transport/downloads`：仅增加 response stage diagnostics及 trace透传。
- tests：冻结 previous 780 对700可抢占、对760不可抢占、maxActive始终1，以及两段 diagnostics可见。
- 不改 NetLane、Reader policy、水位、decoder/upload、rhttp framing、Mihon/Cloudflare。
