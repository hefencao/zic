# ADR 0086：异步 texture schedule 与共享 artifact 读取调度

- 状态：Provisional
- 日期：2026-08-03
- 适用范围：`texture_bridge`、`downloads`、`pipeline_runtime`、测试隔离
- 修正：取代 ADR 0084 中“blit lane 使用 latch 等待 platform thread”的具体实现

## 背景

dev.101 设备 Trace 已将 Android presentation 拆成 platform-thread queue 与 `scheduleFrame()` 调用。样本显示长尾主要发生在 platform-thread 排队，而实际 API 调用通常很短；继续让唯一 blit lane 用 latch 等待 main thread 会把一页的 platform queue 延迟串行传播到其他 current/transition output。

同一 Trace 还显示两个并存 Reader session 各自启动 persistent artifact stream，峰值读取数达到两个 session 局部上限之和。窗口和页面 demand 均由 Pipeline 正常产生，但 composition 缺少跨 session 的本地持久 artifact 读取上限。

错误报告同时证明 Flutter `testWidgets` 的 `skip` 参数只接受布尔值；字符串 quarantine 原因会破坏整个测试文件的编译闭包。

## 决策

1. `texture_bridge` 在 blit/retain/replace 完成后向 Android main handler 异步投递一个 runnable；该 runnable 执行 `SurfaceProducer.scheduleFrame()`，随后在同一 runnable 内回复 MethodChannel。
2. blit lane 不再使用 `CountDownLatch` 或其他同步等待 main thread 的机制。回复仍不得早于 `scheduleFrame()` 执行。
3. `downloads` 提供 composition-shared `ArtifactCacheReadScheduler`，默认最多同时运行 5 个 persistent artifact stream，并为 priority 不低于 900 的 current/transition demand 保留至少一个槽。
4. pending stream 的 priority 由 `pipeline_runtime` 提供的权威 demand callback 动态读取。Reader observation 或 detach 改变 plan 后刷新队列；transition/background 晋升 current 时不取消、不重开同一 stream。
5. active stream 不因 role 变化被取消或重新分类；调度只约束尚未开始的 persistent artifact stream，不改变 7/3、2/1、current/transition upload 或 lane 5/3/2。
6. `sourceRead` 记录取得槽位时的 priority 与 scheduler wait；离线 analyzer 计算跨 session 最大并发。
7. quarantine 使用 `skip: true`，原因以同语句注释中的稳定 `ZIC-QUARANTINE(Q-xxx):` 标记和登记表表达。

## 所有权

- Android surface blit、schedule 与回复顺序：`texture_bridge`。
- persistent artifact stream 并发和 lease：`downloads`。
- 当前 demand priority 与计划变化通知：`pipeline_runtime`。
- quarantine 登记与门禁：repository tooling。

## 被否决方案

- 缩小下载或预解码窗口来降低本地读取并发：掩盖 composition 重复，不修复所有权。
- 让 blit lane 同步等待 main thread：会把 platform queue 长尾传播到其他 output。
- 在 `scheduleFrame()` 之前回复：可能让 playback 先于 texture 可见状态推进。
- role 晋升时取消并重开 artifact stream：会丢弃有效读取并重复 I/O。
- 在 App/Reader 建立私有 semaphore：会泄漏底层资源策略并形成第二权威来源。

## 验证要求

当前仅达到源码审查、静态门禁、Kotlin stub 编译和 host-native 验证。需要 dev.102 Android Trace 证明跨 Reader persistent artifact 最大并发受控、current/transition 能取得保留槽，并比较异步 schedule 后的 presentation 长尾；完成前保持 Provisional。
