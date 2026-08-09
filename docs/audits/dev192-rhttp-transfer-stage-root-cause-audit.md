# dev.192 rhttp 持续传输阶段根因审计

## 输入

`zic-debug-trace-2026-08-09T15-08-46.jsonl`，dev.191。

16个已结束origin source-read样本：

- request-plan median约1.455s，p90约2.816s；
- plan hook median约0.393s；
- bridge network cache hits median=3，origin calls median=1，说明dev.191 resolver cache已明显命中；
- host-open median约0.433s，p90约1.114s；
- body stream median约3.004s，p90约9.428s，max约9.884s；
- Dart sourceRead最大chunk gap median约165ms，max约361ms；
- 已结束流吞吐中位约0.785MiB/s（按bytes/streamMicros近似），范围很大。

按origin开始时priority粗分，current=1000样本的持续吞吐并不稳定高于780/820；同时存在mid-stream近似单流的约0.42MiB/s慢样本。由此不能把剩余问题归结为ZIC已有“带宽scheduler限速”：origin body没有通过ArtifactCacheReadScheduler，NetLane只控制启动/取消/并发，不在receiving后分配字节配额。另一方面也不能直接新增带宽调度，因为部分低吞吐在无明显竞争时仍存在，和来源/CDN慢流一致。

## 当前未知分界

现有`sourceRead`只能看到Dart消费`ByteResponse.bytes`后的event cadence。部分长流出现数千个约1460-byte事件，但无法判断：

1. rhttp/reqwest本身就以稀疏小块接收；
2. rhttp内部已累计更多字节，但FFI/Dart Stream交付滞后；
3. consumer pull/backpressure让body stream停顿。

因此本轮不恢复ADR 0162已被ADR 0165取代的64/256KiB transport aggregation，也不增加current带宽token bucket。

## 修改边界

在rhttp direct bridge增加receive-progress与raw-body observation；以`ByteResponseReadDiagnostics`只读seam将最终snapshot附加到现有`sourceRead`。记录HTTP version和匿名remote-IP hash辅助判断同endpoint/协议差异。所有`sourceRhttp*`字段禁止进入Reader/Pipeline/session policy。
