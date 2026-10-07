# ADR 0175：rhttp 持续传输分段观测边界

## 状态

Accepted。补充 ADR 0161、0165、0174；本轮只增强持续传输观测，不增加带宽调度、transport framing 或 Reader/Pipeline 网络策略。

## 问题

`zic-debug-trace-2026-08-09T15-08-46.jsonl` 的16个已结束 origin source-read 样本确认 dev.191 resolver cache 已生效：`sourcePlanBridgeNetworkCacheHits`中位为3、`sourcePlanBridgeNetworkOriginCalls`中位为1，hook中位约0.393s，host-open中位约0.433s。剩余长尾主要移到最终图片 body：`streamMicros`中位约3.004s、p90约9.428s，Dart侧最大chunk gap中位约165ms、最大约361ms。

同一trace中，current=1000并不稳定获得最高持续吞吐；另一方面存在近似单流阶段仍只有约0.42MiB/s的慢流。因此当前证据既不支持“已有带宽调度器限速”，也不足以证明“新增current带宽配额”就是正确修复。当前origin HTTP开始后没有字节级token bucket/lease；NetLane只拥有admission、并发和preemption。还需区分源/CDN/rhttp接收节拍与rhttp body交付到Dart的节拍。

## 决策

1. `RhttpSourceResourceDirectTransport`继续保持ADR 0165的raw body cadence；不恢复64/256KiB transport buffer，不新增第二framing owner。
2. 使用rhttp 0.18已有`onReceiveProgress`作为rhttp receive-progress观测，同时在最靠近`HttpStreamResponse.body`的bridge边界记录raw body event。两者只用于比较接收进度与body交付，不宣称progress callback等价于socket/TCP packet时序。该逐事件 instrumentation 仅在非product构建启用；product/release不注册额外progress callback，生产传输行为保持dev.191不变。
3. `ByteResponse`增加可选`ByteResponseReadDiagnostics` observation seam；实现可以在body消费过程中更新统计，最终由现有`sourceRead` trace在stream结束/取消时snapshot。该接口不得提供pause/resume、priority、quota或scheduler能力。
4. trace新增HTTP version、匿名remote-IP hash、rhttp progress/body事件数、首事件时间、最大gap、最大delta/chunk以及progress领先body的最大/最终字节数。匿名remote-IP hash只用于同一trace比较host endpoint，不存储原IP。
5. `sourceRhttp*`字段禁止进入sessions、pipeline_runtime或App policy；它们不能参与NetLane rank、retry、cache、holder水位或Reader决策。
6. 下一步只有在设备证据显示rhttp receive-progress明显领先Dart body delivery时，才调查FFI/stream backpressure；若两者同步出现长gap，则优先视为源/CDN/HTTP链路问题。只有确认并发active streams持续损害current且底层pause能真实反压到网络时，才设计NetLane-owned transfer pressure。

## 后果

- 下一份trace可以把“远端/rhttp接收慢”与“rhttp已经收到但Dart body交付慢”拆开，而不改变生产下载行为。
- 当前5路network、current reserved +1、1000/820/800/780、7/3与DownloadJob 16/64KiB单一聚合保持不变。
- instrumentation会引入轻量progress callback计数；不得据此直接增加transport聚合或新的Reader bandwidth scheduler。
