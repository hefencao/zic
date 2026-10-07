# ADR 0230：unsupported source body 的 consumer-paced 伪pause

状态：Accepted

## 问题

dev.249/250只允许声明`streamBackpressure`的response执行动画frame credit。16:42真机Trace确认direct主路径已产生35次`paused`与22次`resumed`，但不支持真实upstream pause的source body会完全绕过credit。另一方面，Trace里limited但未pause的多数任务来自persistent artifact-cache；这些字节已本地durable，不应为了视觉一致性故意阻塞。

## 决策

1. `ByteResponseFlowControl`继续由transport唯一拥有，增加`consumerPacing`：表示consumer可以安全停止迭代并稍后继续同一body，但不承诺降低已经materialize/buffer的上游网络字节。
2. runtime source fallback与generic `LoaderTransport`显式声明`consumerPacing`；direct HttpClient/rhttp继续声明`streamBackpressure`；artifact-cache/resident保持既有快速本地读取，不声明伪pause。
3. `DownloadJob`只对`bodyAuthority=source`且flow capability非`none`建立同一个WebP frame gate。真实pause记录`paused/resumed`，伪pause记录`pseudo-paused/pseudo-resumed`；两者均不得cancel/reopen或重建physical session。
4. 不在本ADR提高NetLane连接数，也不把flow-paused task从5个active body slot计数中排除。正确释放body permit需要完整的resume-permit arbitration；半实现会在多个paused task同时提水位时冲穿并发上限。该问题独立保留。

## 后果

支持真实backpressure的来源继续节省网络body；unsupported-but-safe source获得一致的frame-credit行为与partial深度，但pseudo trace明确不声称节省其已materialize上游流量。scheduler/identity/partial ownership不变。
