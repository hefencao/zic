# ADR 0158：Venera Transport 抢占与 Native Source Lock 所有权

状态：Accepted
版本：0.31.0-dev.175

## 背景

`dev.174` 已修复饱和 `NetLane` handoff 调度，但设备 Trace 继续显示：current 已进入 reserved network handoff 后，仍会在 `source-loader` 等待数秒才取得 response。说明外层调度决定正确，但 cancellation/priority identity 在 `Transport.open()` 边界丢失；与此同时 Venera 为保证单一 JavaScript request context，仍将来源调用串行化。

同一 Trace 的下载 `bytesCommitted` 还出现十几到三十余毫秒的 `nativeIngressMicros` 尖峰。Native 检查发现 `zic_cursor_decode_next()` 在 WebP decode、scale、composite 全程持有 byte source 的 `RwLock` 读锁，而 Dart 下载 ingress 同步调用的 reserve/commit 需要写锁，因此后台解码能反向阻塞 UI isolate。

## 决策

1. `NetLane` 仍是唯一 network scheduler。它拥有的 task 通过只读 `TaskControl` 暴露 cancellation 与动态 priority；transport、catalog、plugin runtime只能观察，不得建立竞争调度策略。
2. Reader page transport 端到端使用 `ControlledTransport`。controlled request-plan不得复用另一 task 的 in-flight Future，否则会继承对方的队列位置和取消身份。
3. Venera 继续只有一个 runtime invocation context。permit移交时选择实时 `TaskControl.priority` 最高的未取消 waiter；active controlled invocation被取消时沿既有 `cancel(requestId)` 下沉。priority不能通过增加第二个 JavaScript/WebView invocation实现。
4. shared direct HTTP replay 在 request已经创建后接入 task cancellation；真实 operation退出前仍不释放 lane permit。
5. Native incremental decode持有 source读锁的范围只包括 demux刷新与复制下一帧所需的精确压缩 fragment。WebP decode、缩放、合成与 frame/canvas copy必须在锁外完成。
6. encoded prefetch/decode窗口与 network/decode/upload lane数量保持不变。本轮修复 ownership/锁竞争，不通过减少工作量掩盖问题。

## 后果

- current一旦赢得 `NetLane`，同一个优先级/取消身份可以继续进入 Venera request-plan，不再在插件层重新退化为独立 FIFO。
- prefetch被抢占后，其 active Venera request可以实际取消，唯一 runtime permit退出后优先交给 current，同时保持单上下文语义。
- 下载 append仍是同步 FFI边界，但 native source lock不再覆盖整帧耗时解码，因此主 isolate不应再等待后台 worker完整解码。
- 普通 metadata/artwork 等 uncontrolled调用继续保留原 request coalescing，不获得 Reader scheduler语义。
