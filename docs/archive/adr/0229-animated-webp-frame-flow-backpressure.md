# ADR 0229：稳定3/7内的动画WebP frame-flow backpressure

状态：Accepted。取代 ADR0227 的2/4 network eligibility与 ADR0228 的estimated whole-body weighted admission；保留3/7逻辑窗口、水位顺序与dev.246 destructive-preemption边界。

## 问题

14:13真机Trace中dev.247/248把动画normal scrolling/idle从11个download demand降到7，`downloadPreempted`降到13，证明减小并行工作有效；但这优先优化了跨版本partial/极端连接保留，退化了更常见的“用户只浏览几帧就切页”场景。动画页通常154/173帧，浪费来自远端task继续读取整张十几MiB body，而不是3/7页面本身不应有demand。

## 决策

1. `RoleResolver`与`DownloadDemand`都恢复previous3/next7；3/7成员资格、跳页retention与physical identity继续统一。
2. `AnimatedPrefetchPolicy`只输出per-page `flowTargetFrames`：current/可见transition=0(unlimited)，next=5、next2=3、previous=2，其余远端=1；既有`c>4/n>2/c>6/n>3`水位只将对应外层提高到2。runtime确认static时全部credit=0。
3. `DownloadDemand -> TransferDemand -> NetLane CancelToken`携带`flowTargetFrames`；credit变化不得重建task。
4. `DownloadJob`以轻量RIFF/ANMF边界计数完整动画帧。达到credit后先flush已收到字节到authoritative partial，再停止请求下一`StreamIterator.moveNext()`；credit提高或变current后同一response继续。
5. `ByteResponse`显式声明`streamBackpressure` capability。HttpClient/rhttp direct提供该能力；artifact-cache、resident immutable、整包runtime/loadBytes路径不声明，sessions不得按source名称猜测。
6. NetLane不再执行dev.248 `estimatedTransferBytes/speculativeBudgetBytes` whole-body admission。网络并发本轮仍normal5+current-reserved1；不同时提高paused socket上限，后续只在设备证据证明paused task长期占槽时单独设计bounded retained-connection pool。

## 非目标

- 不把frame credit变成动画事实或decode owner。
- 不用cancel/reopen模拟pause。
- 不修改dev.246 current destructive-preemption transaction或physical partial authority。
